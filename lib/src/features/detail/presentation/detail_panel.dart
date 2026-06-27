import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../../app/theme/design_tokens.dart';
import '../../cli_detection/presentation/imported_session_view.dart';
import '../../git/application/changes_providers.dart';
import '../../git/presentation/changes_view.dart';
import '../../github/application/github_providers.dart';
import '../../github/presentation/github_view.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/session_transcript_view.dart';

/// Whether the detail right-sidebar (Changes / GitHub / Info) is shown.
class DetailSidebarVisibleController extends Notifier<bool> {
  @override
  bool build() => true;
  void toggle() => state = !state;
}

final detailSidebarVisibleProvider =
    NotifierProvider<DetailSidebarVisibleController, bool>(
      DetailSidebarVisibleController.new,
    );

/// Right pane — a VS Code-style detail area: the conversation (chat transcript)
/// fills the main column, while Git changes, GitHub and session info live in a
/// collapsible right sidebar.
class DetailPanel extends ConsumerWidget {
  const DetailPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.detail;
    final selectedRepoId = ref.watch(selectedRepositoryIdProvider);
    final sidebarVisible = ref.watch(detailSidebarVisibleProvider);
    final showSidebar = sidebarVisible && selectedRepoId != null;

    return PaneScaffold(
      title: 'Detail',
      icon: Icons.article_outlined,
      focused: focused,
      actions: [
        if (selectedRepoId != null)
          IconButton(
            tooltip: sidebarVisible ? 'Hide sidebar' : 'Show sidebar',
            isSelected: sidebarVisible,
            icon: const Icon(Icons.view_sidebar_outlined, size: 18),
            onPressed: () =>
                ref.read(detailSidebarVisibleProvider.notifier).toggle(),
          ),
      ],
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: _MainArea()),
          if (showSidebar) ...[
            const VerticalDivider(width: 1),
            const SizedBox(width: 340, child: _Sidebar()),
          ],
        ],
      ),
    );
  }
}

class _MainArea extends ConsumerWidget {
  const _MainArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedProjectId = ref.watch(selectedProjectIdProvider);
    final selectedRepoId = ref.watch(selectedRepositoryIdProvider);
    final selectedSessionId = ref.watch(selectedSessionIdProvider);
    final selectedImportedId = ref.watch(selectedImportedSessionIdProvider);
    final repositories = ref.watch(selectedProjectRepositoriesProvider);

    if (selectedImportedId != null) {
      return ImportedSessionView(sessionId: selectedImportedId);
    }
    if (selectedSessionId != null) {
      return SessionTranscriptView(sessionId: selectedSessionId);
    }
    if (selectedRepoId != null) {
      return const PanePlaceholder(
        message:
            'Open a session from the Explorer to chat here.\n'
            'Git changes and GitHub are in the sidebar →',
      );
    }
    if (selectedProjectId == null) {
      return const PanePlaceholder(
        message: 'Select a project to see its repositories.',
      );
    }
    if (repositories.isEmpty) {
      return const PanePlaceholder(
        message:
            'No Git repositories were found in this project folder.\n'
            'Add repositories to the folder and rescan.',
      );
    }
    return ListView.builder(
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
          onTap: () {
            ref.read(selectedChangeFileProvider.notifier).select(null);
            ref.read(selectedSessionIdProvider.notifier).select(null);
            ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
          },
        );
      },
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(repoReviewTabProvider);
    final repos = ref.watch(selectedProjectRepositoriesProvider);
    final repoId = ref.watch(selectedRepositoryIdProvider);
    final repo = repos.where((r) => r.id == repoId).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.difference_outlined, size: 15),
                label: Text('Changes'),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.merge_outlined, size: 15),
                label: Text('GitHub'),
              ),
              ButtonSegment(
                value: 2,
                icon: Icon(Icons.info_outline, size: 15),
                label: Text('Info'),
              ),
            ],
            selected: {tab},
            onSelectionChanged: (s) =>
                ref.read(repoReviewTabProvider.notifier).select(s.first),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (tab) {
            0 => ChangesView(repositoryName: repo?.name ?? 'repository'),
            1 => const GitHubView(),
            _ => _InfoView(repo: repo),
          },
        ),
      ],
    );
  }
}

class _InfoView extends ConsumerWidget {
  const _InfoView({required this.repo});
  final Repository? repo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projectId = ref.watch(selectedProjectIdProvider);
    final project = ref
        .watch(projectsControllerProvider)
        .where((p) => p.id == projectId)
        .firstOrNull;

    final rows = <(String, String)>[
      if (project != null) ('Project', project.name),
      if (project != null) ('Project root', project.root.path),
      if (repo != null) ('Repository', repo!.name),
      if (repo != null) ('Path', repo!.path.path),
      if (repo != null) ('Environment', repo!.path.environmentId),
    ];

    if (rows.isEmpty) {
      return const PanePlaceholder(message: 'No selection.');
    }

    return ListView(
      padding: const EdgeInsets.all(Insets.md),
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
