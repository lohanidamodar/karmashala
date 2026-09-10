import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/delivery.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_activity_strip.dart';
import 'companion_approval_card.dart';
import 'companion_chrome.dart';
import 'companion_composer.dart';
import 'companion_route.dart';
import 'companion_states.dart';
import 'companion_status_badge.dart';
import 'companion_transcript_view.dart';
import 'link_banner.dart';

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

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
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
    final canPrompt = gateway.capabilities.has(Capability.sendPrompt);
    final canApprove = gateway.capabilities.has(Capability.approve);
    final canAttach = gateway.capabilities.has(Capability.sendAttachment);
    // A null summary is normal while sessions.list is arriving; once the list
    // has a value it is authoritative and the controls must go.
    final sessionGone = sessions.hasValue && session == null;
    final imported = session?.imported ?? false;
    final resumeOffer = !sessionGone &&
        session != null &&
        (imported ||
            session.status == CompanionSessionStatus.idle ||
            session.status == CompanionSessionStatus.failed ||
            session.status == CompanionSessionStatus.unknown);

    // Hoisted out so the readable-width wrapper below stays one line.
    final pane = sessionGone
        ? CompanionNotice(
            icon: AppIcons.folder,
            title: 'Session no longer available',
            body: _resumeFailure ??
                'The desktop no longer lists this session. Go back and '
                    'choose another session.',
            tone: NoticeTone.attention,
          )
        : companionAsync(
      transcript,
      loading: () => link == CompanionLinkState.connected
          ? const Center(child: CircularProgressIndicator())
          // No link to carry anything, so a skeleton would be a promise the
          // phone cannot keep.
          : CompanionNotice(
              icon: AppIcons.linkBreak,
              title: 'Waiting for your desktop',
              body:
                  "This session's messages arrive as soon as the link is "
                  'back.',
              tone: NoticeTone.attention,
              actionLabel: 'Try again',
              onAction: () {
                gateway.reconnect();
                ref.invalidate(companionTranscriptProvider(sessionId));
              },
            ),
      error: (e) => CompanionNotice.failure(
        error: e,
        onRetry: () {
          gateway.reconnect();
          ref.invalidate(companionTranscriptProvider(sessionId));
        },
      ),
      data: (messages) => CompanionTranscriptView(
        messages: messages,
        // Two nothings the phone cannot tell apart: an agent that keeps no
        // readable transcript, and a session that has not spoken yet.
        emptyHint:
            'No transcript to show. Some agents keep none we can read — '
            'their terminal is the session — and a session that has just '
            'started has nothing in it yet.',
        // Starter prompts are onboarding, which is only true of a session that
        // has not started — and never of a phone that may not send one.
        onSuggestionTap:
            canPrompt && session?.status != CompanionSessionStatus.working
            ? (prompt) {
                _composer.text = prompt;
                _composer.selection = TextSelection.collapsed(
                  offset: prompt.length,
                );
              }
            : null,
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Above the composer, because nothing typed is read until the
            // prompt is answered.
            if (!sessionGone && approval != null && !imported)
              CompanionApprovalCard(
                approval: approval,
                canAnswer: canApprove,
                onAnswer: (decision) =>
                    gateway.answerApproval(sessionId, approval.id, decision),
              ),
            // Directly above the composer, as the desktop puts it: the
            // transcript's tail could only answer "what now" by not moving.
            if (!sessionGone && !imported)
              CompanionActivityStrip(sessionId: sessionId),
            if (resumeOffer)
              _ResumePanel(
                busy: _resuming,
                failure: _resumeFailure,
                enabled: gateway.capabilities.has(Capability.startSession) &&
                    link == CompanionLinkState.connected,
                disabledLabel: !gateway.capabilities.has(Capability.startSession)
                    ? 'Resume permission not granted'
                    : 'Connect to resume',
                onResume: () => _resume(sessionId),
              ),
            if (!sessionGone && !imported)
              CompanionComposer(
                controller: _composer,
                enabled: canPrompt && !imported,
                hintText: canPrompt
                    ? 'Send a message…'
                    : 'This phone was not granted prompt rights.',
                // Straight off the row, so the picker appears only where the
                // host has said what it would take.
                attachments: canAttach ? session?.attachments : null,
                onSend: (text, {attachment, onProgress}) async {
                  final delivery = await gateway.sendPrompt(
                    sessionId,
                    text,
                    attachment: attachment,
                    onProgress: onProgress,
                  );
                  if (delivery == RemotePromptDelivery.offered &&
                      context.mounted) {
                    // The file lands in the desktop's message box, so this must
                    // not read as though the agent already had it.
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Waiting in the desktop\'s message box — send it '
                          'from there.',
                        ),
                      ),
                    );
                  }
                },
              ),
          ],
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
            // compact breakpoint (CLAUDE.md §6).
            CompanionReadable(
              child: Padding(
                // What only this session can answer: its status, and where it
                // is.
                padding: EdgeInsets.symmetric(
                  horizontal: density.padX,
                  vertical: density.isTouch ? Insets.sm : Insets.xs,
                ),
                child: Row(
                  children: [
                    if (session != null)
                      CompanionStatusBadge(
                        status: session.status,
                        showLabel: true,
                      ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        [
                          if (session?.agentLabel != null) session!.agentLabel,
                          if (session?.whereabouts != null)
                            session!.whereabouts!,
                          if (session?.deliveryStage != null)
                            SessionViewScreen._stageLabel(
                              session!.deliveryStage!,
                            ),
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: density.muted(theme),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const CompanionReadable(child: Divider(height: 1)),
            // NOT `AsyncValue.when`: a provider being retried is
            // `AsyncLoading` *carrying* its error, so `when` takes the loading
            // branch and this screen spins for ever.
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
        setState(() => _resumeFailure = 'The active desktop changed while '
            'this session was being resumed. Try again.');
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
        if (failure != null)
          Text(
            failure!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        FilledButton.icon(
          onPressed: !enabled || busy ? null : onResume,
          icon: busy
              ? const SizedBox.square(
                  dimension: Touch.iconSmall,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.play),
          label: Text(
            !enabled
                ? disabledLabel
                : busy
                ? 'Resuming…'
                : 'Resume session',
          ),
        ),
      ],
    ),
  );
}
