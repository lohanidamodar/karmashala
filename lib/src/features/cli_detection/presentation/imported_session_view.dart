import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/chat_transcript.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/cli_detection_providers.dart';

/// Read-only history for an imported CLI session, rendered like the chat
/// transcript. Continue it in-app (Resume) or open it in an external terminal.
class ImportedSessionView extends ConsumerWidget {
  const ImportedSessionView({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    ref.watch(sessionsRevisionProvider);
    final session = ref.read(importedSessionDaoProvider).getById(sessionId);

    if (session == null) {
      return const Center(child: Text('Imported session not found.'));
    }

    final transcript = ref.watch(importedTranscriptProvider(sessionId));
    final terminals = ref.watch(availableSystemTerminalsProvider);

    Future<void> resume() async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref.read(sessionActionsProvider).resumeImported(session);
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text(e is StateError ? e.message : '$e')),
        );
      }
    }

    Future<void> openIn(SystemTerminal terminal) async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref
            .read(sessionActionsProvider)
            .openInSystemTerminal(session, terminal);
        messenger.showSnackBar(
          SnackBar(content: Text('Opening in ${terminal.label}…')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text(e is StateError ? e.message : '$e')),
        );
      }
    }

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
                onPressed: () => ref
                    .read(selectedImportedSessionIdProvider.notifier)
                    .select(null),
              ),
              Expanded(
                child: Text(
                  session.displayTitle,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              terminals.maybeWhen(
                data: (list) => list.isEmpty
                    ? const SizedBox.shrink()
                    : PopupMenuButton<SystemTerminal>(
                        tooltip: 'Open in system terminal',
                        icon: const Icon(Icons.open_in_new, size: 18),
                        onSelected: openIn,
                        itemBuilder: (context) => [
                          for (final t in list)
                            PopupMenuItem(
                              value: t,
                              child: Text('Open in ${t.label}'),
                            ),
                        ],
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
              const SizedBox(width: 4),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Resume'),
                onPressed: resume,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: transcript.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not read history: $e')),
            data: (messages) => ChatTranscriptView(
              messages: [
                for (final m in messages)
                  ChatMessage(role: m.role, text: m.text),
              ],
              emptyHint: 'This session has no readable history.',
            ),
          ),
        ),
      ],
    );
  }
}
