import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_kind.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/cli_detection_providers.dart';

/// Read-only detail for an imported CLI session: where it came from and where it
/// lives on disk. (Resuming imported sessions arrives in a later loop.)
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

    final cliLabel = session.cli == AgentKind.codex ? 'Codex' : 'Claude Code';
    final rows = <(String, String)>[
      ('Source', cliLabel),
      ('Environment', session.environmentId),
      ('CLI session id', session.externalId),
      if (session.isSubagent) ('Kind', 'Subagent (SDK-spawned)'),
      ('File', session.filePath),
      if (session.updatedAt != null)
        ('Last active', session.updatedAt!.toLocal().toString()),
    ];

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
              FilledButton.tonalIcon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Resume'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await ref
                        .read(sessionActionsProvider)
                        .resumeImported(session);
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(e is StateError ? e.message : '$e'),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Insets.lg),
            children: [
              Text('IMPORTED CLI SESSION', style: theme.textTheme.labelSmall),
              const SizedBox(height: Insets.sm),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 120,
                        child: Text(label, style: theme.textTheme.bodySmall),
                      ),
                      Expanded(
                        child: SelectableText(
                          value,
                          style: const TextStyle(
                            fontFamily: kMonoFamily,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (session.preview.isNotEmpty) ...[
                const SizedBox(height: Insets.md),
                Text('FIRST MESSAGE', style: theme.textTheme.labelSmall),
                const SizedBox(height: Insets.xs),
                Text(session.preview, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
