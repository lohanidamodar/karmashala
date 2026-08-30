import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../git/application/changes_providers.dart';
import '../../git/domain/git_commit.dart';
import '../../git/domain/git_worktree.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/domain/repository.dart';

/// What the app knows about the current project and repository: paths, the
/// execution environment, and live Git facts read straight from the repo.
class RepositoryInfoView extends ConsumerWidget {
  const RepositoryInfoView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projectId = ref.watch(selectedProjectIdProvider);
    final repoId = ref.watch(selectedRepositoryIdProvider);
    final repo = ref
        .watch(selectedProjectRepositoriesProvider)
        .where((r) => r.id == repoId)
        .firstOrNull;
    final project = ref
        .watch(projectsControllerProvider)
        .where((p) => p.id == projectId)
        .firstOrNull;

    final rows = <(String, String)>[
      if (project != null) ('Project', project.name),
      if (project != null) ('Project root', project.root.path),
      if (repo != null) ('Repository', repo.name),
      if (repo != null) ('Path', repo.path.path),
      if (repo != null) ('Environment', repo.path.environmentId),
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
        if (repo != null) ...[
          const Divider(height: Insets.md),
          const _GitDetails(),
        ],
      ],
    );
  }
}

/// Local Git details for the selected repository: branch, remote, worktrees and
/// recent commits. Git is authoritative; these read live.
class _GitDetails extends ConsumerWidget {
  const _GitDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final branch = ref.watch(currentBranchProvider);
    final remote = ref.watch(repoRemoteUrlProvider);
    final worktrees = ref.watch(repoWorktreesProvider);
    final commits = ref.watch(recentCommitsProvider);

    String textOf(AsyncValue<String?> v, String fallback) => switch (v) {
      AsyncData(:final value) => value ?? fallback,
      AsyncError() => 'unavailable',
      _ => '…',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(theme, 'GIT'),
        _kv(theme, 'Branch', textOf(branch, 'detached')),
        _kv(theme, 'Remote', textOf(remote, 'none')),
        const SizedBox(height: Insets.md),
        _label(theme, 'WORKTREES'),
        worktrees.when(
          loading: () => _dim(theme, '…'),
          error: (_, _) => _dim(theme, 'unavailable'),
          data: (list) => list.isEmpty
              ? _dim(theme, 'none')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final GitWorktree w in list)
                      _line(
                        theme,
                        w.branch ?? '(detached)',
                        w.path.path,
                        icon: AppIcons.gitBranch,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Insets.md),
        _label(theme, 'RECENT COMMITS'),
        commits.when(
          loading: () => _dim(theme, '…'),
          error: (_, _) => _dim(theme, 'unavailable'),
          data: (list) => list.isEmpty
              ? _dim(theme, 'none')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final GitCommit c in list)
                      _line(
                        theme,
                        c.sha.length >= 7 ? c.sha.substring(0, 7) : c.sha,
                        c.subject,
                        icon: AppIcons.gitDiff,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  static Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: theme.textTheme.labelSmall),
  );

  static Widget _kv(ThemeData theme, String key, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            key,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12),
          ),
        ),
      ],
    ),
  );

  static Widget _line(
    ThemeData theme,
    String lead,
    String rest, {
    required IconData icon,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          lead,
          style: const TextStyle(fontFamily: kMonoFamily, fontSize: 11.5),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            rest,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );

  static Widget _dim(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

/// The repository whose name the Changes view should title itself with.
Repository? selectedRepository(WidgetRef ref) {
  final repoId = ref.watch(selectedRepositoryIdProvider);
  return ref
      .watch(selectedProjectRepositoriesProvider)
      .where((r) => r.id == repoId)
      .firstOrNull;
}
