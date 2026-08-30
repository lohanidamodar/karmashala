import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../remote/protocol.dart';
import '../../sessions/domain/delivery_stage.dart';
import '../../sessions/presentation/chat_transcript.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_approval_card.dart';
import 'companion_composer.dart';
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
    final scheme = theme.colorScheme;
    final gateway = ref.read(companionGatewayProvider);
    final session = ref.watch(companionSessionProvider(sessionId));
    final transcript = ref.watch(companionTranscriptProvider(sessionId));
    final approval = ref
        .watch(companionApprovalProvider(sessionId))
        .asData
        ?.value;
    final canPrompt = gateway.capabilities.has(Capability.sendPrompt);
    final canApprove = gateway.capabilities.has(Capability.approve);

    return Scaffold(
      appBar: AppBar(
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
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.xs,
              Insets.md,
              Insets.xs,
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
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: transcript.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(Insets.xl),
                  child: Text(
                    '$e',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              ),
              data: (messages) => ChatTranscriptView(
                messages: [
                  for (final message in messages)
                    ChatMessage(role: message.role, text: message.text),
                ],
                emptyHint:
                    'Nothing in this session\'s transcript yet — it appears '
                    'once the agent answers.',
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
