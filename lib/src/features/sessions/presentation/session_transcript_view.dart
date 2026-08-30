import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_providers.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/session_actions.dart';
import '../application/session_chat_source.dart';
import '../application/session_engine_provider.dart';
import '../application/session_providers.dart';
import '../application/session_ui_providers.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import '../domain/session_launch.dart';
import 'agent_status_badge.dart';
import 'approval_request_card.dart';
import 'chat_transcript.dart';
import 'delivery_strip.dart';
import 'message_composer.dart';
import 'permission_mode_chip.dart';
import 'session_repositories_bar.dart';

/// The chat transcript for the selected native session, rendered CLI-style. Only
/// conversational events are shown — lifecycle/status noise is filtered out.
class SessionTranscriptView extends ConsumerStatefulWidget {
  const SessionTranscriptView({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionTranscriptView> createState() =>
      _SessionTranscriptViewState();
}

class _SessionTranscriptViewState extends ConsumerState<SessionTranscriptView> {
  Future<void> _stop() async {
    await ref.read(sessionEngineProvider).stop(widget.sessionId);
    ref.read(sessionsRevisionProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionsRevisionProvider);
    final session = ref.read(sessionDaoProvider).getById(widget.sessionId);
    // A PTY-hosted session's conversation lives in the agent's own transcript,
    // because an interactive agent has no structured stream on stdout to read
    // (see `SessionTranscriptLocator`). A session from before the PTY runtime
    // still renders from the engine's event log.
    final fromPty = session?.surface == SessionSurface.pane;
    final transcript = fromPty
        ? ref
              .watch(sessionChatTranscriptProvider(widget.sessionId))
              .whenData(_fromTranscript)
        : ref.watch(sessionTranscriptProvider).whenData(_toMessages);
    final active =
        fromPty || ref.read(sessionEngineProvider).isActive(widget.sessionId);
    // Whether a chat rendering is possible at all for this agent — a registry
    // question, not a runtime one. Antigravity and any agent added as data have
    // the same PTY as Claude Code; they simply have no readable record of the
    // conversation to draw a transcript from.
    final chatAvailable = !fromPty || sessionHasChatView(ref, widget.sessionId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // No title and no back button: the workbench tab above already names
        // the session and closes it, and the strip's Chat/Terminal toggle
        // already switches the view. What is left is what only this session
        // can answer — what it is doing, and how to stop it.
        SizedBox(
          height: Chrome.tabStrip,
          child: Row(
            children: [
              const SizedBox(width: Insets.md),
              AgentStatusBadge(sessionId: widget.sessionId, showLabel: true),
              const Spacer(),
              _OpenInTerminalButton(sessionId: widget.sessionId),
              if (active)
                IconButton(
                  tooltip: 'Stop session',
                  icon: const Icon(AppIcons.stopCircle, size: 18),
                  onPressed: _stop,
                ),
              const SizedBox(width: Insets.xs),
            ],
          ),
        ),
        SessionRepositoriesBar(sessionId: widget.sessionId),
        const Divider(height: 1),
        Expanded(
          child: transcript.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (messages) => ChatTranscriptView(
              messages: messages,
              // The delivery strip sits on the composer's channel: its prompt
              // actions send through `continueSession`, so they are available
              // in exactly the same circumstances.
              footer: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Above the handoff row and the composer, because it is the
                  // thing blocking the session: nothing the user types will be
                  // read until the agent's prompt is answered.
                  ApprovalRequestCard(sessionId: widget.sessionId),
                  DeliveryStrip(sessionId: widget.sessionId),
                  MessageComposer(
                    // MonoCode's chip row: the session's own safety policy,
                    // where the message is written rather than buried in
                    // Settings under the agent's name.
                    chips: [PermissionModeChip(sessionId: widget.sessionId)],
                    hintText: active
                        ? 'Message the agent…  (attach an image with 🖼)'
                        : 'Type to continue this session…',
                    onSend: (text) => ref
                        .read(sessionActionsProvider)
                        .continueSession(widget.sessionId, text),
                  ),
                ],
              ),
              emptyHint: !chatAvailable
                  ? 'This agent keeps no transcript we can read, so there is no '
                        'chat view for it. Its terminal is the session.'
                  : fromPty
                  ? 'Nothing in this session\'s transcript yet — it appears '
                        'once the agent answers. The terminal shows it live.'
                  : active
                  ? 'Session is running — say something to the agent.'
                  : 'No messages yet.',
            ),
          ),
        ),
      ],
    );
  }

  /// The agent's own transcript as chat messages. Tool lines are dropped: the
  /// terminal view already shows them, in the form the agent drew them.
  List<ChatMessage> _fromTranscript(List<TranscriptMessage> messages) => [
    for (final message in messages)
      if (message.role != 'tool')
        ChatMessage(role: message.role, text: message.text),
  ];

  /// Maps the persisted event log to displayable chat messages, dropping
  /// lifecycle/status noise (verbose logs are not shown in the chat).
  List<ChatMessage> _toMessages(List<SessionEvent> events) {
    final messages = <ChatMessage>[];
    for (final event in events) {
      // Surface conversation turns and any failure, but keep ordinary
      // lifecycle/status chatter out of the chat.
      switch (event.type) {
        case SessionEventTypes.userMessage:
          _addText(messages, 'user', event.payload);
        case SessionEventTypes.agentMessage:
          _addText(messages, 'agent', event.payload);
        case SessionEventTypes.error:
          _addText(messages, 'error', event.payload);
        case SessionEventTypes.sessionFailed:
          messages.add(
            const ChatMessage(role: 'error', text: 'Session failed.'),
          );
        case SessionEventTypes.sessionCancelled:
          messages.add(const ChatMessage(role: 'tool', text: 'Session ended.'));
      }
    }
    return messages;
  }

  void _addText(List<ChatMessage> out, String role, String payload) {
    final text = _text(payload);
    if (text.isNotEmpty) out.add(ChatMessage(role: role, text: text));
  }

  String _text(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return (decoded['text'] ?? '').toString();
      }
    } on FormatException {
      // not JSON
    }
    return '';
  }
}

/// A header action that opens the session in one of the installed external
/// terminals (Windows Terminal, WezTerm, …), running its agent in the repo.
class _OpenInTerminalButton extends ConsumerWidget {
  const _OpenInTerminalButton({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminals = ref.watch(availableSystemTerminalsProvider);
    return terminals.maybeWhen(
      data: (list) => list.isEmpty
          ? const SizedBox.shrink()
          : PopupMenuButton<SystemTerminal>(
              tooltip: 'Open in system terminal',
              icon: const Icon(AppIcons.arrowSquareOut, size: 18),
              onSelected: (terminal) async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ref
                      .read(sessionActionsProvider)
                      .openSessionInSystemTerminal(sessionId, terminal);
                  messenger.showSnackBar(
                    SnackBar(content: Text('Opening in ${terminal.label}…')),
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text(e is StateError ? e.message : '$e')),
                  );
                }
              },
              itemBuilder: (context) => [
                for (final t in list)
                  PopupMenuItem(
                    value: t,
                    height: 32,
                    child: Row(
                      children: [
                        const Icon(AppIcons.terminal, size: 16),
                        const SizedBox(width: 10),
                        Text('Open in ${t.label}'),
                      ],
                    ),
                  ),
              ],
            ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// Whether a chat view can be built for the agent behind [sessionId].
///
/// A capability question about the *agent*, answered from the registry — not a
/// question about which runtime the session uses, because every in-app session
/// uses the same one.
bool sessionHasChatView(WidgetRef ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return false;
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  if (agentId == null) return false;
  return agentSupportsChatView(ref.read(agentRegistryProvider).byId(agentId));
}
