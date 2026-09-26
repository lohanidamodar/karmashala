import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import '../../editor/application/code_editor_providers.dart';
import 'package:agent_cli/process.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/chat_transcript.dart';
import '../../sessions/presentation/message_composer.dart';
import '../../terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

/// History for an imported CLI session, rendered like the chat transcript.
/// Typing a message resumes it in place, replacing the imported entry.
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
    // One imported record, drawn by id. Another session moving says nothing
    // about it.
    ref.watchSession(widget.sessionId);
    final session = ref
        .read(importedSessionsProvider)
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
                icon: const Icon(AppIcons.arrowLeft),
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
                        icon: const Icon(AppIcons.arrowSquareOut),
                        onSelected: (t) => _openIn(session, t),
                        itemBuilder: (context) => [
                          for (final t in list)
                            DesktopMenuItem(
                              value: t,
                              label: 'Open in ${t.label}',
                              icon: AppIcons.terminal,
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
            loading: () => const Center(
              child: InlineSpinner(size: InlineSpinnerSize.large),
            ),
            error: (e, _) => Center(child: Text('Could not read history: $e')),
            data: (messages) => ChatTranscriptView(
              messages: [
                for (final m in messages)
                  ChatMessage(role: m.role, text: m.text, tool: m.tool),
              ],
              // An imported session records paths in the environment it ran in;
              // an image read in WSL needs its host form before `dart:io` can.
              resolveHostPath: (path) => ref
                  .read(editorActionsProvider)
                  .windowsPathFor(
                    EnvironmentPath(
                      environmentId: session.environmentId,
                      path: path,
                    ),
                  ),
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
