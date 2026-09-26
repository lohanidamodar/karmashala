import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/delivery.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_activity_strip.dart';
import 'companion_approval_card.dart';
import 'companion_menu_card.dart';
import 'companion_question_card.dart';
import 'companion_chrome.dart';
import 'companion_composer.dart';
import 'companion_route.dart';
import 'companion_states.dart';
import 'companion_status_badge.dart';
import 'session_controls_sheet.dart';
import 'companion_transcript_view.dart';
import 'link_banner.dart';

/// Whether the session view offers Resume for [session]: an imported session,
/// or one whose process is not running and is not working. Never before the
/// session list is known, never for a session the list no longer has, and
/// never for a live one — an agent idle at its own prompt is sent a message.
bool companionOffersResume(
  CompanionSessionSummary? session, {
  required bool listKnown,
}) =>
    listKnown &&
    session != null &&
    (session.imported ||
        (!session.live &&
            (session.status == CompanionSessionStatus.idle ||
                session.status == CompanionSessionStatus.failed ||
                session.status == CompanionSessionStatus.unknown)));

/// One session's transcript on the phone: the desktop chat's shapes drawn
/// bottom-up by [CompanionTranscriptView], with the composer reduced to what
/// the protocol lets a phone do — send a prompt, answer an approval.
class SessionViewScreen extends ConsumerStatefulWidget {
  const SessionViewScreen({required this.sessionId, super.key});

  final String sessionId;

  /// The desktop's own wording for a stage name off the wire, with the raw name
  /// as the fallback for a stage this build predates.
  static String _stageLabel(String stage) =>
      DeliveryStage.values.asNameMap()[stage]?.label ?? stage;

  @override
  ConsumerState<SessionViewScreen> createState() => _SessionViewScreenState();
}

class _SessionViewScreenState extends ConsumerState<SessionViewScreen> {
  final _composer = TextEditingController();
  bool _resuming = false;
  String? _resumeFailure;
  late final String _resumeKey;

  /// Captured in [initState] so [dispose] never reaches for `ref`.
  late final CompanionGateway _gateway;

  @override
  void initState() {
    super.initState();
    _resumeKey = _newRequestId();
    _gateway = ref.read(companionGatewayProvider);
    // Presence routes a notification and never gates a delivery, so the desktop
    // can still push news about a session that is not on screen.
    unawaited(_gateway.reportFocusedSession(widget.sessionId));
  }

  String _newRequestId() => ref.read(companionIdGeneratorProvider).newId();

  @override
  void dispose() {
    unawaited(_gateway.reportFocusedSession(null));
    _composer.dispose();
    super.dispose();
  }

  void _retryTranscript() {
    ref.read(companionGatewayProvider).reconnect();
    ref.invalidate(companionTranscriptProvider(widget.sessionId));
  }

  void _suggest(String prompt) {
    _composer.text = prompt;
    _composer.selection = TextSelection.collapsed(offset: prompt.length);
  }

  Future<void> _send(
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
    String? requestId,
  }) async {
    final delivery = await ref
        .read(companionGatewayProvider)
        .sendPrompt(
          widget.sessionId,
          text,
          attachment: attachment,
          onProgress: onProgress,
          requestId: requestId,
        );
    if (delivery == RemotePromptDelivery.offered && mounted) {
      // The file lands in the desktop's message box, so this must not read as
      // though the agent already had it.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Waiting in the desktop\'s message box — send it from there.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final gateway = ref.read(companionGatewayProvider);
    final sessions = ref.watch(companionSessionsProvider);
    final session = ref.watch(companionSessionProvider(sessionId));
    final transcript = ref.watch(companionTranscriptProvider(sessionId));
    final approval = ref
        .watch(companionApprovalProvider(sessionId))
        .asData
        ?.value;
    final link = ref.watch(companionLinkProvider).asData?.value;
    // A card that simply vanishes reads as a dropped request. Events-only, so
    // a screen that opened after the fact announces nothing.
    ref.listen(companionApprovalResolutionProvider(sessionId), (_, next) {
      final resolution = next.asData?.value;
      if (resolution == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(resolution.outcome.sentence)));
    });
    final capabilities = gateway.capabilities;
    final canPrompt = capabilities.has(Capability.sendPrompt);
    final canResume = capabilities.has(Capability.startSession);
    // A null summary is normal while sessions.list is arriving; once the list
    // has a value it is authoritative and the controls must go.
    final sessionGone = sessions.hasValue && session == null;
    final imported = session?.imported ?? false;
    // A prompt is open on the desktop: typed text would land in it, and its
    // Enter would pick whatever is highlighted. The host refuses the send, so
    // the phone does not offer one.
    final prompted =
        !imported &&
        approval != null &&
        (approval.menu != null ||
            approval.question != null ||
            approval.waiting == RemoteWaitKind.approval ||
            approval.waiting == RemoteWaitKind.question);

    final pane = sessionGone
        ? CompanionNotice(
            icon: AppIcons.folder,
            title: 'Session no longer available',
            body:
                _resumeFailure ??
                'The desktop no longer lists this session. Go back and '
                    'choose another session.',
            tone: NoticeTone.attention,
          )
        // NOT `AsyncValue.when`: a provider being retried is `AsyncLoading`
        // *carrying* its error, so `when` takes the loading branch and this
        // screen spins for ever.
        : companionAsync(
            transcript,
            loading: () => link == CompanionLinkState.connected
                ? const Center(
                    child: InlineSpinner(size: InlineSpinnerSize.large),
                  )
                // No link to carry anything, so a skeleton would be a promise
                // the phone cannot keep.
                : CompanionNotice(
                    icon: AppIcons.linkBreak,
                    title: 'Waiting for your desktop',
                    body:
                        "This session's messages arrive as soon as the link "
                        'is back.',
                    tone: NoticeTone.attention,
                    actionLabel: 'Try again',
                    onAction: _retryTranscript,
                  ),
            error: (e) =>
                CompanionNotice.failure(error: e, onRetry: _retryTranscript),
            data: (messages) => CompanionTranscriptView(
              messages: messages,
              // Two nothings the phone cannot tell apart: an agent that keeps
              // no readable transcript, and a session that has not spoken yet.
              emptyHint:
                  'No transcript to show. Some agents keep none we can read — '
                  'their terminal is the session — and a session that has '
                  'just started has nothing in it yet.',
              // Starter prompts are onboarding, which is only true of a
              // session that has not started — and never of a phone that may
              // not send one.
              onSuggestionTap:
                  canPrompt &&
                      !prompted &&
                      session?.status != CompanionSessionStatus.working
                  ? _suggest
                  : null,
              footer: SessionFooter(
                sessionId: sessionId,
                approval: imported ? null : approval,
                canApprove: capabilities.has(Capability.approve),
                onAnswer: (decision) => approval == null
                    ? Future<void>.value()
                    : gateway.answerApproval(sessionId, approval.id, decision),
                onAnswerQuestion: (answers, {decline = false}) =>
                    approval == null
                    ? Future<void>.value()
                    : gateway.answerQuestion(
                        sessionId,
                        approval.id,
                        answers: answers,
                        decline: decline,
                      ),
                onAnswerMenu: (option) => approval == null
                    ? Future<void>.value()
                    : gateway.answerMenu(sessionId, approval.id, option),
                showActivity: !imported,
                resume:
                    companionOffersResume(session, listKnown: sessions.hasValue)
                    ? _ResumePanel(
                        busy: _resuming,
                        failure: _resumeFailure,
                        enabled:
                            canResume && link == CompanionLinkState.connected,
                        disabledLabel: canResume
                            ? 'Connect to resume'
                            : 'Resume permission not granted',
                        onResume: () => _resume(sessionId),
                      )
                    : null,
              ),
              composer: imported
                  ? null
                  : CompanionComposer(
                      controller: _composer,
                      enabled: canPrompt && !prompted,
                      hintText: !canPrompt
                          ? 'This phone was not granted prompt rights.'
                          : prompted
                          ? 'Answer the prompt above first'
                          : 'Send a message…',
                      // Straight off the row, so the picker appears only where
                      // the host has said what it would take.
                      attachments: capabilities.has(Capability.sendAttachment)
                          ? session?.attachments
                          : null,
                      newRequestId: _newRequestId,
                      onSend: _send,
                    ),
            ),
          );

    return Scaffold(
      appBar: companionAppBar(
        context,
        title: Text(
          session?.title ?? 'Session',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // Without this the composer's send button sits under Android's gesture
      // bar.
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Full-bleed above the column: an outage is chrome, not content.
            const LinkBanner(),
            // Everything below is content and keeps a phone's measure past the
            // compact breakpoint (CLAUDE.md §6). The status line gives way to
            // the composer when the keyboard leaves too little height for both.
            if (!companionKeyboardSqueezed(context)) ...[
              CompanionReadable(
                child: SessionStatusStrip(
                  status: session?.status,
                  agentLabel: session?.agentLabel,
                  model: session?.model,
                  whereabouts: session?.whereabouts,
                  stageLabel: switch (session?.deliveryStage) {
                    final stage? => SessionViewScreen._stageLabel(stage),
                    null => null,
                  },
                  // Imported history has no running session to change.
                  onTap: session == null || session.imported
                      ? null
                      : () => showSessionControls(context, session.id),
                ),
              ),
              const CompanionReadable(child: Divider(height: 1)),
            ],
            Expanded(child: CompanionReadable(child: pane)),
          ],
        ),
      ),
    );
  }

  Future<void> _resume(String sessionId) async {
    if (_resuming) return;
    final gateway = ref.read(companionGatewayProvider);
    final hostBefore = gateway.pairing?.hostId;
    setState(() {
      _resuming = true;
      _resumeFailure = null;
    });
    try {
      final started = await gateway.resumeSession(
        requestId: _resumeKey,
        sessionId: sessionId,
      );
      if (!mounted) return;
      final hostAfter = gateway.pairing?.hostId;
      if (hostBefore != hostAfter) {
        setState(
          () => _resumeFailure =
              'The active desktop changed while '
              'this session was being resumed. Try again.',
        );
        return;
      }
      Navigator.of(context).pushReplacement(
        companionRoute<void>(
          context,
          (_) => SessionViewScreen(sessionId: started.sessionId),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _resumeFailure = companionErrorText(error));
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }
}

/// What only this session can answer, above its transcript: its status, and
/// the agent, where it is open and its delivery stage in one muted line.
class SessionStatusStrip extends StatelessWidget {
  const SessionStatusStrip({
    this.status,
    this.agentLabel,
    this.model,
    this.whereabouts,
    this.stageLabel,
    this.onTap,
    super.key,
  });

  /// Opens the session's model and permission pickers; null draws no control.
  final VoidCallback? onTap;

  /// Null while the session list is still arriving: no badge, not a guess.
  final CompanionSessionStatus? status;
  final String? agentLabel;

  /// Beside the agent, before anything the line may cut off.
  final String? model;
  final String? whereabouts;
  final String? stageLabel;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final status = this.status;
    final strip = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: density.padX,
        vertical: density.isTouch ? Insets.sm : Insets.xs,
      ),
      child: Row(
        children: [
          if (status != null)
            CompanionStatusBadge(status: status, showLabel: true),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              [?agentLabel, ?model, ?whereabouts, ?stageLabel].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: density.muted(Theme.of(context)),
            ),
          ),
          if (onTap != null) ...[
            SizedBox(width: density.glyphGap),
            Icon(
              AppIcons.caretDown,
              size: density.icon,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
    final tap = onTap;
    if (tap == null) return strip;
    return Semantics(
      button: true,
      label: 'Change model or permission mode',
      child: InkWell(onTap: tap, child: strip),
    );
  }
}

/// Between the transcript and the composer: the pending approval, what the
/// session is running, and the offer to resume it — in that order.
class SessionFooter extends StatelessWidget {
  const SessionFooter({
    required this.sessionId,
    required this.onAnswer,
    this.onAnswerQuestion,
    this.onAnswerMenu,
    this.approval,
    this.canApprove = false,
    this.showActivity = true,
    this.resume,
    super.key,
  });

  final String sessionId;

  /// Drawn above everything else, because nothing typed is read until the
  /// prompt is answered.
  final CompanionApproval? approval;

  /// Whether this phone holds the `approve` capability.
  final bool canApprove;
  final Future<void> Function(CompanionApprovalDecision decision) onAnswer;
  final CompanionQuestionAnswerFn? onAnswerQuestion;
  final CompanionMenuAnswerFn? onAnswerMenu;

  /// The activity strip, directly above the composer as the desktop puts it.
  final bool showActivity;

  /// The resume panel, when the session offers one.
  final Widget? resume;

  @override
  Widget build(BuildContext context) {
    final approval = this.approval;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (approval != null)
          CompanionApprovalCard(
            approval: approval,
            canAnswer: canApprove,
            onAnswer: onAnswer,
            onAnswerQuestion: onAnswerQuestion,
            onAnswerMenu: onAnswerMenu,
          ),
        if (showActivity) CompanionActivityStrip(sessionId: sessionId),
        ?resume,
      ],
    );
  }
}

class _ResumePanel extends StatelessWidget {
  const _ResumePanel({
    required this.busy,
    required this.onResume,
    required this.enabled,
    required this.disabledLabel,
    this.failure,
  });

  final bool busy;
  final bool enabled;
  final String disabledLabel;
  final String? failure;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Insets.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failure case final failure?) ...[
          CompanionInlineError(failure),
          const SizedBox(height: Insets.sm),
        ],
        CompanionPrimaryButton(
          busy: busy,
          onPressed: enabled ? onResume : null,
          icon: AppIcons.play,
          label: !enabled
              ? disabledLabel
              : busy
              ? 'Resuming…'
              : 'Resume session',
        ),
      ],
    ),
  );
}
