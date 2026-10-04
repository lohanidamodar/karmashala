import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../application/session_status_providers.dart';
import '../approval_request_card.dart';

/// Sessions whose open ask the chat is drawing under its call right now. The
/// dock steps aside for them, so one set of answers is on screen.
final chatInlineAsksProvider = NotifierProvider<ChatInlineAsks, Set<String>>(
  ChatInlineAsks.new,
);

class ChatInlineAsks extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void shown(String sessionId) {
    if (!state.contains(sessionId)) state = {...state, sessionId};
  }

  void gone(String sessionId) {
    if (state.contains(sessionId)) {
      state = {...state}..remove(sessionId);
    }
  }
}

/// Whether [report] is asking about the call [toolUseId]: an approval whose
/// hook or protocol request named that call.
bool asksAboutCall(AgentStatusReport? report, String toolUseId) =>
    report != null &&
    report.status == AgentActivityStatus.awaitingApproval &&
    report.waiting == AgentWaitKind.approval &&
    report.toolAsk?.toolUseId == toolUseId;

/// **The pending approval, under the call it is about.** The dock's own card
/// and answers, so either place answers the one prompt and both clear when
/// the agent moves on. Nothing at all for any other call.
class ChatToolAsk extends ConsumerStatefulWidget {
  const ChatToolAsk({
    required this.sessionId,
    required this.toolUseId,
    super.key,
  });

  final String sessionId;
  final String toolUseId;

  @override
  ConsumerState<ChatToolAsk> createState() => _ChatToolAskState();
}

class _ChatToolAskState extends ConsumerState<ChatToolAsk> {
  late final ChatInlineAsks _asks;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _asks = ref.read(chatInlineAsksProvider.notifier);
  }

  @override
  void dispose() {
    if (_shown) _tell(false);
    super.dispose();
  }

  /// Told after the frame: a provider may not change while the tree builds.
  void _tell(bool shown) {
    _shown = shown;
    final sessionId = widget.sessionId;
    scheduleMicrotask(() {
      try {
        shown ? _asks.shown(sessionId) : _asks.gone(sessionId);
      } on StateError {
        // The scope went with the tree.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final asking = ref.watch(
      agentSessionStatusProvider(
        widget.sessionId,
      ).select((s) => asksAboutCall(s.asData?.value, widget.toolUseId)),
    );
    if (asking != _shown) _tell(asking);
    if (!asking) return const SizedBox.shrink();
    return Padding(
      key: ValueKey('chat-ask:${widget.toolUseId}'),
      padding: const EdgeInsets.only(top: Insets.sm),
      child: ApprovalRequestCard(
        sessionId: widget.sessionId,
        docked: true,
        inline: true,
        touch: UiDensity.of(context).isTouch,
      ),
    );
  }
}
