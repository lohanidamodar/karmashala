import '../../workspaces/data/workspace_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/repositories.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../../app/widgets/fact_list.dart';
import '../application/session_providers.dart';
import '../application/session_repositories_service.dart';
import '../application/session_ui_providers.dart';

/// What a session's repositories offer: the ones it spans, primary first,
/// and the ones it may attach.
class _Repositories {
  _Repositories(WidgetRef ref, this.sessionId)
    : repos = ref.watch(sessionRepositoriesProvider(sessionId)),
      workspace = ref.read(workspaceDataProvider),
      service = ref.read(sessionRepositoriesServiceProvider);

  final String sessionId;
  final List<Repository> repos;
  final WorkspaceData workspace;
  final SessionRepositoriesService service;

  Repository get primary => repos.first;

  /// A session in a project attaches that project's checkouts; one without
  /// a project — running in Scratch — may attach any in the workspace.
  bool get scratch => workspace.project(primary.projectId)?.isScratch ?? false;

  List<Repository> get attachable {
    final linkedIds = repos.map((r) => r.id).toSet();
    return (scratch
            ? workspace.repositories.where(
                (r) => r.projectId != primary.projectId,
              )
            : workspace.repositoriesOf(primary.projectId))
        .where((r) => !linkedIds.contains(r.id))
        .toList();
  }

  /// Whether a repository is this session's own tree or a checkout it
  /// shares, by repository: the one thing a reader cannot see from the name.
  /// Null for this session's own worktree, so the tooltip only warns.
  Map<String, String?> get notes => {
    for (final checkout in service.checkoutsFor(sessionId))
      checkout.repositoryId: checkout.note,
  };

  String get addTooltip => scratch
      ? 'Add a repository from the workspace'
      : 'Add a repository from this project';

  List<PopupMenuEntry<String>> addItems() => [
    for (final repo in attachable)
      DesktopMenuItem(
        value: repo.id,
        // Across projects two checkouts can share a name; the project tells
        // them apart.
        label: scratch
            ? '${workspace.project(repo.projectId)?.name ?? '?'} · '
                  '${repo.name}'
            : repo.name,
        icon: AppIcons.linkSimple,
      ),
  ];

  /// Attaching or detaching a checkout moves where this session works, and
  /// nothing else about it.
  Future<void> _change(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() change,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await change();
      ref.publishSessionChange(SessionChange.moved(sessionId));
    } on SessionRepositoryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> attach(BuildContext context, WidgetRef ref, String repoId) =>
      _change(context, ref, () => service.attach(sessionId, repoId));

  Future<void> detach(BuildContext context, WidgetRef ref, String repoId) =>
      _change(context, ref, () => service.detach(sessionId, repoId));
}

/// Shows the repositories a session spans (primary first) and lets the user
/// attach more from the same project or detach additional ones (Loop 13).
class SessionRepositoriesBar extends ConsumerWidget {
  const SessionRepositoriesBar({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositories = _Repositories(ref, sessionId);
    final repos = repositories.repos;
    if (repos.isEmpty) return const SizedBox.shrink();
    final primary = repositories.primary;
    final attachable = repositories.attachable;
    final notes = repositories.notes;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, Insets.sm, 0),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final repo in repos)
            InputChip(
              label: Text(repo.name),
              avatar: repo.id == primary.id
                  ? const Icon(AppIcons.star, size: Chrome.iconAction)
                  : const Icon(AppIcons.gitBranch, size: Chrome.iconAction),
              tooltip: notes[repo.id],
              onDeleted: repo.id == primary.id
                  ? null
                  : () => repositories.detach(context, ref, repo.id),
            ),
          if (attachable.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: repositories.addTooltip,
              onSelected: (repoId) => repositories.attach(context, ref, repoId),
              itemBuilder: (_) => repositories.addItems(),
              child: const Chip(
                avatar: Icon(AppIcons.plus, size: Chrome.iconAction),
                label: Text('Add repo'),
              ),
            ),
        ],
      ),
    );
  }
}

/// **The session's repositories as list rows**: one per repository, the
/// primary starred and saying so, any other with its Detach, then **Add
/// repository…** while there is one to add. Nothing for a session in none.
class SessionRepositoryRows extends ConsumerWidget {
  const SessionRepositoryRows({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositories = _Repositories(ref, sessionId);
    final repos = repositories.repos;
    if (repos.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final primary = repositories.primary;
    final notes = repositories.notes;
    final attachable = repositories.attachable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final repo in repos)
          Tooltip(
            message: notes[repo.id] ?? '',
            child: FactRow(
              key: ValueKey('session-repository:${repo.id}'),
              icon: AppIcons.gitBranch,
              leading: repo.id == primary.id
                  ? Icon(
                      AppIcons.star,
                      size: Chrome.icon,
                      color: scheme.primary,
                    )
                  : null,
              label: repo.name,
              value: repo.id == primary.id
                  ? Text('Primary', style: muted)
                  : IconButton(
                      key: ValueKey('session-repository-detach:${repo.id}'),
                      tooltip: 'Detach ${repo.name}',
                      visualDensity: VisualDensity.compact,
                      iconSize: Chrome.iconSmall,
                      onPressed: () =>
                          repositories.detach(context, ref, repo.id),
                      icon: const Icon(AppIcons.x),
                    ),
            ),
          ),
        if (attachable.isNotEmpty)
          Builder(
            builder: (row) => FactRow(
              key: const ValueKey('session-repository-add'),
              icon: AppIcons.plus,
              label: 'Add repository…',
              chevron: true,
              onTap: () async {
                final picked = await showDesktopMenuUnder(
                  row,
                  repositories.addItems(),
                );
                if (picked != null && context.mounted) {
                  await repositories.attach(context, ref, picked);
                }
              },
            ),
          ),
      ],
    );
  }
}
