import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../remote/protocol.dart';
import '../../sessions/domain/delivery_stage.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_approval_card.dart';
import 'companion_chrome.dart';
import 'companion_composer.dart';
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

  /// The desktop's own wording for a stage name off the wire — rebuilt from
  /// the typed enum, with the raw name as the honest fallback for a stage
  /// this build predates.
  static String _stageLabel(String stage) =>
      DeliveryStage.values.asNameMap()[stage]?.label ?? stage;

  @override
  ConsumerState<SessionViewScreen> createState() => _SessionViewScreenState();
}

class _SessionViewScreenState extends ConsumerState<SessionViewScreen> {
  final _composer = TextEditingController();

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final gateway = ref.read(companionGatewayProvider);
    final session = ref.watch(companionSessionProvider(sessionId));
    final transcript = ref.watch(companionTranscriptProvider(sessionId));
    final approval = ref
        .watch(companionApprovalProvider(sessionId))
        .asData
        ?.value;
    final link = ref.watch(companionLinkProvider).asData?.value;
    // A card that simply vanishes reads as a dropped request, so the reason
    // is said out loud. Events-only, so nothing is announced to a screen that
    // opened after the fact.
    ref.listen(companionApprovalResolutionProvider(sessionId), (_, next) {
      final resolution = next.asData?.value;
      if (resolution == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(resolution.outcome.sentence)));
    });
    final canPrompt = gateway.capabilities.has(Capability.sendPrompt);
    final canApprove = gateway.capabilities.has(Capability.approve);

    // Hoisted out of the tree so the readable-width wrapper below reads as
    // one line rather than another level of nesting.
    final pane = companionAsync(
      transcript,
      loading: () => link == CompanionLinkState.connected
          ? const Center(child: CircularProgressIndicator())
          // Nothing is on its way, because there is no link to carry it. A
          // skeleton here is a promise the phone cannot keep.
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
        // Two different nothings the phone cannot tell apart: an agent that
        // keeps no readable transcript (its terminal IS the session, as the
        // desktop says) and a session that has not spoken yet. Claiming
        // either one would be a guess.
        emptyHint:
            'No transcript to show. Some agents keep none we can read — '
            'their terminal is the session — and a session that has just '
            'started has nothing in it yet.',
        onSuggestionTap: (prompt) {
          _composer.text = prompt;
          _composer.selection = TextSelection.collapsed(
            offset: prompt.length,
          );
        },
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Above the composer, because it blocks the session: nothing
            // typed is read until the prompt is answered.
            if (approval != null)
              CompanionApprovalCard(
                approval: approval,
                canAnswer: canApprove,
                onAnswer: (decision) =>
                    gateway.answerApproval(sessionId, approval.id, decision),
              ),
            CompanionComposer(
              controller: _composer,
              enabled: canPrompt,
              hintText: canPrompt
                  ? 'Message the agent…'
                  : 'This phone was not granted prompt rights.',
              onSend: (text) => gateway.sendPrompt(sessionId, text),
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
      // The composer is the bottom-most thing on the screen, so without this
      // its send button sat under the gesture bar on every modern Android.
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Full-bleed above the column, the way the shell draws it: an
            // outage is chrome, not content.
            const LinkBanner(),
            // Everything below is content, and past the compact breakpoint it
            // keeps a phone's measure — a transcript, a status line and a
            // composer set across a tablet are three lines nobody can read
            // together (CLAUDE.md §6).
            CompanionReadable(
              child: Padding(
                // What only this session can answer: its status, and where
                // it is.
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
            // NOT `AsyncValue.when`: Riverpod 3 retries a provider that
            // failed and reports `AsyncLoading` *carrying* the error, so
            // `when` takes its loading branch and this screen sat on a
            // spinner for ever — the "I opened a session and it keeps
            // loading" report. `companionAsync` asks the questions in the
            // order a user cares about.
            Expanded(child: CompanionReadable(child: pane)),
          ],
        ),
      ),
    );
  }
}
