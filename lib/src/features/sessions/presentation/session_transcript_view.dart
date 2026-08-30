import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../agents/application/agent_providers.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/session_actions.dart';
import '../application/session_engine_provider.dart';
import '../application/session_providers.dart';
import '../application/session_ui_providers.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import '../domain/session_launch.dart';
import 'agent_status_badge.dart';
import 'chat_transcript.dart';
import 'handoff_actions_row.dart';
import 'message_composer.dart';
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
                icon: const Icon(AppIcons.arrowLeft, size: 18),
                onPressed: () =>
                    ref.read(selectedSessionIdProvider.notifier).select(null),
              ),
              Expanded(
                child: Text('Transcript', style: theme.textTheme.titleSmall),
              ),
              AgentStatusBadge(sessionId: widget.sessionId, showLabel: true),
              const SizedBox(width: 8),
              _ShowTerminalButton(sessionId: widget.sessionId),
              _OpenInTerminalButton(sessionId: widget.sessionId),
              if (active)
                IconButton(
                  tooltip: 'Stop session',
                  icon: const Icon(AppIcons.stopCircle, size: 18),
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
              // The handoff row sits on the composer's channel: both send
              // through `continueSession`, so both are available in exactly the
              // same circumstances.
              footer: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HandoffActionsRow(sessionId: widget.sessionId),
                  MessageComposer(
                    hintText: active
                        ? 'Message the agent…  (attach an image with 🖼)'
                        : 'Type to continue this session…',
                    onSend: (text) => ref
                        .read(sessionActionsProvider)
                        .continueSession(widget.sessionId, text),
                  ),
                ],
              ),
              emptyHint: active
                  ? 'Session is running — say something to the agent.'
                  : 'No messages yet.',
            ),
          ),
        ),
      ],
    );
  }

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

/// Switches this session to its terminal view.
///
/// Chat and terminal are two renderings of **one** session — same row, same PTY,
/// same lifecycle — so this starts and stops nothing. It reveals the pane the
/// agent is already running in and records the preference, and the session is
/// entirely unaffected either way.
///
/// Absent for a session with no pane of ours (an external terminal, or a session
/// from before this existed), because there would be nothing to show.
class _ShowTerminalButton extends ConsumerWidget {
  const _ShowTerminalButton({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(sessionsRevisionProvider);
    final session = ref.read(sessionDaoProvider).getById(sessionId);
    final paneId = session?.paneId;
    if (paneId == null) return const SizedBox.shrink();

    return IconButton(
      tooltip: 'Show the terminal this session is running in',
      icon: const Icon(AppIcons.terminal, size: 18),
      onPressed: () {
        final terminals = ref.read(terminalSessionsControllerProvider.notifier);
        // A detached pane comes back as a tab; one already in a tab is simply
        // focused. Neither recreates anything.
        terminals
          ..reattachSession(paneId)
          ..focusPane(paneId);
        ref.read(terminalVisibleProvider.notifier).set(true);
        ref
            .read(sessionDaoProvider)
            .updateView(sessionId, SessionView.terminal);
        ref.read(sessionsRevisionProvider.notifier).bump();
      },
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
