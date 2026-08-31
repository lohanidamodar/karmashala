import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../remote/protocol.dart';
import '../../sessions/domain/delivery_stage.dart';
import '../../sessions/presentation/chat_transcript.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_approval_card.dart';
import 'companion_composer.dart';
import 'companion_states.dart';
import 'companion_status_badge.dart';
import 'link_banner.dart';

/// One session's transcript on the phone: the desktop chat view (Loop 41/49)
/// with the composer reduced to what the protocol lets a phone do — send a
/// prompt, answer an approval.
class SessionViewScreen extends ConsumerWidget {
  const SessionViewScreen({required this.sessionId, super.key});

  final String sessionId;

  /// The desktop's own wording for a stage name off the wire — rebuilt from
  /// the typed enum, with the raw name as the honest fallback for a stage
  /// this build predates.
  static String _stageLabel(String stage) =>
      DeliveryStage.values.asNameMap()[stage]?.label ?? stage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final canPrompt = gateway.capabilities.has(Capability.sendPrompt);
    final canApprove = gateway.capabilities.has(Capability.approve);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: density.isTouch
            ? Touch.appBarOf(context)
            : Chrome.titleBarOf(context),
        title: Text(
          session?.title ?? 'Session',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LinkBanner(),
          // What only this session can answer: its status, and where it is.
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: density.padX,
              vertical: density.isTouch ? Insets.sm : Insets.xs,
            ),
            child: Row(
              children: [
                if (session != null)
                  CompanionStatusBadge(status: session.status, showLabel: true),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    [
                      if (session?.agentLabel != null) session!.agentLabel,
                      if (session?.whereabouts != null) session!.whereabouts!,
                      if (session?.deliveryStage != null)
                        _stageLabel(session!.deliveryStage!),
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
          const Divider(height: 1),
          Expanded(
            // NOT `AsyncValue.when`: Riverpod 3 retries a provider that
            // failed and reports `AsyncLoading` *carrying* the error, so
            // `when` takes its loading branch and this screen sat on a
            // spinner for ever — the "I opened a session and it keeps
            // loading" report. `companionAsync` asks the questions in the
            // order a user cares about.
            child: companionAsync(
              transcript,
              loading: () => link == CompanionLinkState.connected
                  ? const Center(child: CircularProgressIndicator())
                  // Nothing is on its way, because there is no link to carry
                  // it. A skeleton here is a promise the phone cannot keep.
                  : CompanionNotice(
                      icon: AppIcons.linkBreak,
                      title: 'Waiting for your desktop',
                      body: "This session's messages arrive as soon as the "
                          'link is back.',
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
              data: (messages) => ChatTranscriptView(
                messages: [
                  for (final message in messages)
                    ChatMessage(role: message.role, text: message.text),
                ],
                // Two different nothings the phone cannot tell apart: an
                // agent that keeps no readable transcript (its terminal IS
                // the session, as the desktop says) and a session that has
                // not spoken yet. Claiming either one would be a guess.
                emptyHint:
                    'No transcript to show. Some agents keep none we can '
                    'read — their terminal is the session — and a session '
                    'that has just started has nothing in it yet.',
                footer: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Above the composer, because it blocks the session:
                    // nothing typed is read until the prompt is answered.
                    if (approval != null)
                      CompanionApprovalCard(
                        approval: approval,
                        canAnswer: canApprove,
                        onAnswer: (decision) => gateway.answerApproval(
                          sessionId,
                          approval.id,
                          decision,
                        ),
                      ),
                    CompanionComposer(
                      enabled: canPrompt,
                      hintText: canPrompt
                          ? 'Message the agent…'
                          : 'This phone was not granted prompt rights.',
                      onSend: (text) => gateway.sendPrompt(sessionId, text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
