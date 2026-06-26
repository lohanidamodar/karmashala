import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../git/application/changes_providers.dart';
import '../../git/presentation/changes_view.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/session_transcript_view.dart';

/// Right pane — Detail. Shows the repositories of the selected project, and when
/// a repository is selected, its Git change/diff review (Loop 9). Session
/// transcripts arrive later.
class DetailPanel extends ConsumerWidget {
  const DetailPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.detail;
    final selectedProjectId = ref.watch(selectedProjectIdProvider);
    final selectedRepoId = ref.watch(selectedRepositoryIdProvider);
    final selectedSessionId = ref.watch(selectedSessionIdProvider);
    final repositories = ref.watch(selectedProjectRepositoriesProvider);

    final Widget body;
    if (selectedSessionId != null) {
      body = SessionTranscriptView(sessionId: selectedSessionId);
    } else if (selectedRepoId != null) {
      final repo = repositories
          .where((r) => r.id == selectedRepoId)
          .firstOrNull;
      body = ChangesView(repositoryName: repo?.name ?? 'repository');
    } else if (selectedProjectId == null) {
      body = const PanePlaceholder(
        message: 'Select a project to see its repositories.',
      );
    } else if (repositories.isEmpty) {
      body = const PanePlaceholder(
        message:
            'No Git repositories were found in this project folder.\n'
            'Add repositories to the folder and rescan.',
      );
    } else {
      body = ListView.builder(
        itemCount: repositories.length,
        itemBuilder: (context, index) {
          final repo = repositories[index];
          return ListTile(
            dense: true,
            leading: const Icon(Icons.source_outlined, size: 18),
            title: Text(repo.name),
            subtitle: Text(
              repo.path.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.difference_outlined, size: 16),
            onTap: () {
              ref.read(selectedChangeFileProvider.notifier).select(null);
              ref.read(selectedSessionIdProvider.notifier).select(null);
              ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
            },
          );
        },
      );
    }

    return PaneScaffold(
      title: 'Detail',
      icon: Icons.article_outlined,
      focused: focused,
      body: body,
    );
  }
}
