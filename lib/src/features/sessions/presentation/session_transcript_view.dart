import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/session_engine_provider.dart';
import '../application/session_ui_providers.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import 'session_repositories_bar.dart';

/// The structured-chat transcript for the selected session, with a message input
/// and a stop control while the session is running.
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
            data: (events) => events.isEmpty
                ? const Center(child: Text('No messages yet.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: events.length,
                    itemBuilder: (context, index) =>
                        _EventTile(event: events[index]),
                  ),
          ),
        ),
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
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});
  final SessionEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _decode(event.payload);
    final text = (data['text'] ?? '').toString();

    final (String label, Color? color, bool muted) = switch (event.type) {
      SessionEventTypes.userMessage => (
        'You',
        theme.colorScheme.primary,
        false,
      ),
      SessionEventTypes.agentMessage => ('Agent', null, false),
      SessionEventTypes.error => ('Error', theme.colorScheme.error, false),
      _ => (event.type, theme.colorScheme.onSurfaceVariant, true),
    };

    final body = text.isNotEmpty ? text : _summary(event.type, data);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            body,
            style: muted
                ? theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _decode(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  String _summary(String type, Map<String, dynamic> data) {
    if (data.containsKey('state')) return '${data['state']}';
    if (data.containsKey('name')) return 'tool: ${data['name']}';
    return type;
  }
}
