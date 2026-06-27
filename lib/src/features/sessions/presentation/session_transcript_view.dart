import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/session_actions.dart';
import '../application/session_engine_provider.dart';
import '../application/session_ui_providers.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import 'chat_transcript.dart';
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
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool _sending = false;

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    _input.clear();
    try {
      await ref
          .read(sessionActionsProvider)
          .continueSession(widget.sessionId, text);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _stop() async {
    await ref.read(sessionEngineProvider).stop(widget.sessionId);
    ref.read(sessionsRevisionProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transcript = ref.watch(sessionTranscriptProvider);
    final active = ref.read(sessionEngineProvider).isActive(widget.sessionId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: () =>
                    ref.read(selectedSessionIdProvider.notifier).select(null),
              ),
              Expanded(
                child: Text('Transcript', style: theme.textTheme.titleSmall),
              ),
              _OpenInTerminalButton(sessionId: widget.sessionId),
              if (active)
                IconButton(
                  tooltip: 'Stop session',
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  onPressed: _stop,
                ),
            ],
          ),
        ),
        SessionRepositoriesBar(sessionId: widget.sessionId),
        const Divider(height: 1),
        Expanded(
          child: transcript.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (events) => ChatTranscriptView(
              messages: _toMessages(events),
              footer: _buildInput(active),
              emptyHint: active
                  ? 'Session is running — say something to the agent.'
                  : 'No messages yet.',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInput(bool active) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                enabled: !_sending,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: active
                      ? 'Message the agent…'
                      : 'Type to continue this session…',
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send, size: 18),
            ),
          ],
        ),
      ),
    ],
  );

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
              icon: const Icon(Icons.open_in_new, size: 18),
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
                  PopupMenuItem(value: t, child: Text('Open in ${t.label}')),
              ],
            ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}
