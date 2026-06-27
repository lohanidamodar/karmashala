import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await ref.read(sessionEngineProvider).sendMessage(widget.sessionId, text);
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
                enabled: active,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: active
                      ? 'Message the agent…'
                      : 'Session is not running',
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: active ? _send : null,
              icon: const Icon(Icons.send, size: 18),
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
      final role = switch (event.type) {
        SessionEventTypes.userMessage => 'user',
        SessionEventTypes.agentMessage => 'agent',
        SessionEventTypes.error => 'error',
        _ => null,
      };
      if (role == null) continue;
      final text = _text(event.payload);
      if (text.isEmpty) continue;
      messages.add(ChatMessage(role: role, text: text));
    }
    return messages;
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
