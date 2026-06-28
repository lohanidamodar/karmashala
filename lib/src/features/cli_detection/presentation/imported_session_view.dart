import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/chat_transcript.dart';
import '../../sessions/presentation/message_composer.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/cli_detection_providers.dart';
import '../domain/imported_session.dart';

/// History for an imported CLI session, rendered like the chat transcript. Typing
/// a message resumes the session in place (it becomes a live session and the
/// imported entry is replaced) — or open it in an external terminal.
class ImportedSessionView extends ConsumerStatefulWidget {
  const ImportedSessionView({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<ImportedSessionView> createState() =>
      _ImportedSessionViewState();
}

class _ImportedSessionViewState extends ConsumerState<ImportedSessionView> {
  Future<void> _openIn(ImportedSession session, SystemTerminal terminal) async {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(sessionsRevisionProvider);
    final session = ref
        .read(importedSessionDaoProvider)
        .getById(widget.sessionId);

    if (session == null) {
      return const Center(child: Text('Imported session not found.'));
    }

    final transcript = ref.watch(importedTranscriptProvider(widget.sessionId));
    final terminals = ref.watch(availableSystemTerminalsProvider);

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
                        icon: const Icon(AppIcons.arrowSquareOut, size: 18),
                        onSelected: (t) => _openIn(session, t),
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
              emptyHint: 'No readable history — send a message to continue it.',
              footer: MessageComposer(
                hintText: 'Continue this session — type a message',
                onSend: (text) => ref
                    .read(sessionActionsProvider)
                    .resumeAndSend(session, text),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
