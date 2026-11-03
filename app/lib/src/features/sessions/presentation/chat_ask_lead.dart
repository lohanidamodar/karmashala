import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentWaitKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench.dart' show CompactWorkbenchScope;
import '../application/secret_requests.dart';
import '../application/session_status_providers.dart';
import 'approval_request_card.dart';
import 'chat_cards/chat_tool_ask.dart' show chatInlineAsksProvider;

/// The share of the chat's footer this may take against the strips beside
/// it, which take one each. A column splits its free room by share whether a
/// strip is empty or not, so the bot's six left a phone's answers scrolled
/// out of sight; the strips fold to a line while this shows anyway.
const _askShare = 24;

/// Below this a bounded card would hold its answers and nothing else, and
/// may not hold them: the whole of it scrolls instead.
const double _askMinBounded = 200;

/// Whether the chat's dock has anything to draw for [String] session: a
/// secret asked for, or a prompt or question no card under its call in the
/// chat answers already — what [ApprovalRequestCard] docked draws.
final chatAskShownProvider = Provider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  if (ref.watch(sessionSecretRequestsProvider(sessionId)).isNotEmpty) {
    return true;
  }
  if (ref.watch(chatInlineAsksProvider.select((s) => s.contains(sessionId)))) {
    return false;
  }
  return ref.watch(
    agentSessionStatusProvider(sessionId).select((s) {
      final report = s.asData?.value;
      return report != null &&
          report.status == AgentActivityStatus.awaitingApproval &&
          (report.waiting == AgentWaitKind.approval ||
              report.waiting == AgentWaitKind.question);
    }),
  );
});

/// **What the session waits on, over its box** (owner, 2026-11-03): a secret
/// it asks for and the prompt it holds — Codex's, read only off the screen,
/// included — answered just above where a reply would be typed, in a chat
/// tab, on the phone and in the dashboard's chat alike. Nothing, and no share
/// of the footer, while it waits on nothing: the strips beside it keep theirs.
class ChatAskLead extends ConsumerWidget {
  const ChatAskLead({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(chatAskShownProvider(sessionId))) {
      return const SizedBox.shrink();
    }
    final touch =
        UiDensity.of(context).isTouch || CompactWorkbenchScope.of(context);
    Widget cards({required bool bounded}) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SecretRequestCard(sessionId: sessionId, touch: touch),
        if (bounded)
          // Bounded: its header stays and a tall ask scrolls under it.
          Flexible(child: _approval(touch))
        else
          _approval(touch),
      ],
    );
    return Flexible(
      flex: _askShare,
      // A short pane under a long draft leaves too little to hold its header
      // and answers both: then the whole of it scrolls instead.
      child: LayoutBuilder(
        builder: (context, box) => box.maxHeight >= _askMinBounded
            ? cards(bounded: true)
            : SingleChildScrollView(
                key: const ValueKey('chat-ask-scroll'),
                primary: false,
                child: cards(bounded: false),
              ),
      ),
    );
  }

  Widget _approval(bool touch) =>
      ApprovalRequestCard(sessionId: sessionId, docked: true, touch: touch);
}
