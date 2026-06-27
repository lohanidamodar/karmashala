import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_kind.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../cli_detection/presentation/detected_projects_view.dart';
import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_status.dart';
import '../../sessions/presentation/new_session_dialog.dart';

/// The unified left pane — an Explorer tree of projects, their repositories and
/// the sessions (native + imported) within each. Selecting/expanding a project
/// reveals its sessions; sessions can be renamed, deleted (and imported ones
/// resumed) from a right-click context menu or the trailing menu button.
class ExplorerPanel extends ConsumerStatefulWidget {
  const ExplorerPanel({super.key});

  @override
  ConsumerState<ExplorerPanel> createState() => _ExplorerPanelState();
}

class _ExplorerPanelState extends ConsumerState<ExplorerPanel> {
  String _query = '';
  final Set<String> _expandedProjects = {};
  final Set<String> _expandedRepos = {};

  void _showDetected() {
    ref.read(detectedProjectsControllerProvider.notifier).detect();
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
          child: const DetectedProjectsView(),
        ),
      ),
    );
  }

  void _toggleProject(Project project) {
    setState(() {
      if (_expandedProjects.remove(project.id)) return;
      _expandedProjects.add(project.id);
    });
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    // Single-repository projects select that repository so "New session" and
    // the detail view have a working context immediately.
    final repos = ref.read(repositoryDaoProvider).getByProject(project.id);
    if (repos.length == 1) {
      ref.read(selectedRepositoryIdProvider.notifier).select(repos.first.id);
    }
  }

  void _toggleRepo(Repository repo) {
    setState(() {
      if (_expandedRepos.remove(repo.id)) return;
      _expandedRepos.add(repo.id);
    });
    ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
  }

  /// Starts a new session in [project]: selects it and its first repository,
  /// then opens the New session dialog (or warns if there are no repositories).
  void _newSessionInProject(Project project) {
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    setState(() => _expandedProjects.add(project.id));
    final repos = ref.read(repositoryDaoProvider).getByProject(project.id);
    if (repos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This project has no Git repositories to run in.'),
        ),
      );
      return;
    }
    ref.read(selectedRepositoryIdProvider.notifier).select(repos.first.id);
    NewSessionDialog.show(context);
  }

  Future<void> _confirmDeleteProject(Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text(
          'Removes "${project.name}" and all its sessions from the workspace. '
          'Files on disk are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      ref.read(projectsControllerProvider.notifier).deleteProject(project.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.explorer;
    final allProjects = ref.watch(projectsControllerProvider);
    // Re-read sessions whenever the workspace mutates.
    ref.watch(sessionsRevisionProvider);

    final query = _query.trim().toLowerCase();
    final projects = query.isEmpty
        ? allProjects
        : allProjects
              .where(
                (p) =>
                    p.name.toLowerCase().contains(query) ||
                    p.root.path.toLowerCase().contains(query),
              )
              .toList();

    final selectedRepoId = ref.watch(selectedRepositoryIdProvider);

    final Widget body;
    if (projects.isEmpty) {
      body = PanePlaceholder(
        message: allProjects.isEmpty
            ? 'No projects yet.\nUse + to create one from a folder, then its '
                  'CLI sessions are imported automatically.'
            : 'No projects match "$_query".',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        children: [for (final project in projects) ..._projectNodes(project)],
      );
    }

    return PaneScaffold(
      title: 'Explorer',
      icon: Icons.account_tree_outlined,
      focused: focused,
      actions: [
        IconButton(
          tooltip: 'Detect CLI sessions',
          icon: const Icon(Icons.travel_explore, size: 18),
          onPressed: _showDetected,
        ),
        IconButton(
          tooltip: selectedRepoId == null
              ? 'Select a repository first'
              : 'New session',
          icon: const Icon(Icons.add_comment_outlined, size: 18),
          onPressed: selectedRepoId == null
              ? null
              : () => NewSessionDialog.show(context),
        ),
        IconButton(
          tooltip: 'New project',
          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
          onPressed: () => NewProjectDialog.show(context),
        ),
      ],
      body: Column(
        children: [
          if (allProjects.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search projects',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// The rows for one project: its header, then (when expanded) its repositories
  /// and sessions.
  List<Widget> _projectNodes(Project project) {
    final selectedProjectId = ref.watch(selectedProjectIdProvider);
    final expanded = _expandedProjects.contains(project.id);
    final rows = <Widget>[
      _TreeRow(
        depth: 0,
        selected: project.id == selectedProjectId,
        leading: Icon(
          expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
          size: 18,
        ),
        expandedState: expanded,
        title: project.name,
        subtitle: project.root.path,
        onTap: () => _toggleProject(project),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'New session in this project',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(Icons.add),
              onPressed: () => _newSessionInProject(project),
            ),
            PopupMenuButton<String>(
              tooltip: 'Project actions',
              icon: const Icon(Icons.more_vert, size: 16),
              onSelected: (action) {
                if (action == 'delete') _confirmDeleteProject(project);
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'delete', child: Text('Delete project')),
              ],
            ),
          ],
        ),
      ),
    ];
    if (!expanded) return rows;

    final repos = ref.read(repositoryDaoProvider).getByProject(project.id);
    if (repos.isEmpty) {
      rows.add(
        const _TreeHint(depth: 1, message: 'No repositories in this project.'),
      );
    } else if (repos.length == 1) {
      rows.addAll(_sessionNodes(repos.first, depth: 1));
    } else {
      for (final repo in repos) {
        rows.addAll(_repoNodes(repo));
      }
    }
    return rows;
  }

  List<Widget> _repoNodes(Repository repo) {
    final selectedRepoId = ref.watch(selectedRepositoryIdProvider);
    final expanded = _expandedRepos.contains(repo.id);
    final rows = <Widget>[
      _TreeRow(
        depth: 1,
        selected: repo.id == selectedRepoId,
        leading: const Icon(Icons.source_outlined, size: 16),
        expandedState: expanded,
        title: repo.name,
        onTap: () => _toggleRepo(repo),
      ),
    ];
    if (expanded) rows.addAll(_sessionNodes(repo, depth: 2));
    return rows;
  }

  List<Widget> _sessionNodes(Repository repo, {required int depth}) {
    final native = ref.read(sessionDaoProvider).getByRepository(repo.id);
    final imported = ref
        .read(importedSessionDaoProvider)
        .getByRepository(repo.id);
    if (native.isEmpty && imported.isEmpty) {
      return [
        _TreeHint(
          depth: depth,
          message: 'No sessions yet — start one with the + above.',
        ),
      ];
    }
    return [
      for (final session in native)
        _NativeSessionRow(session: session, repoId: repo.id, depth: depth),
      for (final session in imported)
        _ImportedSessionRow(session: session, repoId: repo.id, depth: depth),
    ];
  }
}

/// A single expandable/selectable row in the tree (project or repository).
class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.depth,
    required this.selected,
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.expandedState,
    this.trailing,
  });

  final int depth;
  final bool selected;
  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  /// When non-null, a disclosure chevron reflecting expansion state is shown.
  final bool? expandedState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      selected: selected,
      contentPadding: EdgeInsets.only(left: 8.0 + depth * 16, right: 4),
      leading: SizedBox(
        width: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (expandedState != null)
              Icon(
                expandedState! ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              )
            else
              const SizedBox(width: 16),
            const SizedBox(width: 2),
            leading,
          ],
        ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// A non-interactive hint shown under an expanded, empty node.
class _TreeHint extends StatelessWidget {
  const _TreeHint({required this.depth, required this.message});
  final int depth;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8.0 + depth * 16 + 36, 4, 8, 8),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _NativeSessionRow extends ConsumerWidget {
  const _NativeSessionRow({
    required this.session,
    required this.repoId,
    required this.depth,
  });

  final Session session;
  final String repoId;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSessionIdProvider) == session.id;
    final actions = ref.read(sessionActionsProvider);

    Future<void> rename() async {
      final name = await _promptRename(context, session.title);
      if (name != null) actions.renameNative(session.id, name);
    }

    Future<void> delete() async {
      if (await _confirmDelete(context, session.title, cli: false)) {
        actions.deleteNative(session.id);
      }
    }

    void select() {
      ref.read(selectedRepositoryIdProvider.notifier).select(repoId);
      ref.read(selectedImportedSessionIdProvider.notifier).select(null);
      ref.read(selectedSessionIdProvider.notifier).select(session.id);
    }

    return _SessionRow(
      depth: depth,
      selected: selected,
      leading: _statusIcon(session.status, context),
      title: session.title,
      subtitle:
          '${session.status.name}'
          '${session.useWorktree ? ' · worktree' : ''}',
      onTap: select,
      menuItems: const [
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
      onMenu: (action) {
        if (action == 'rename') rename();
        if (action == 'delete') delete();
      },
    );
  }

  Widget _statusIcon(SessionStatus status, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (status) {
      SessionStatus.running => (Icons.play_circle_outline, scheme.tertiary),
      SessionStatus.completed => (Icons.check_circle_outline, Colors.green),
      SessionStatus.failed => (Icons.error_outline, scheme.error),
      SessionStatus.cancelled => (Icons.cancel_outlined, scheme.outline),
      _ => (Icons.radio_button_unchecked, scheme.outline),
    };
    return Icon(icon, size: 16, color: color);
  }
}

class _ImportedSessionRow extends ConsumerWidget {
  const _ImportedSessionRow({
    required this.session,
    required this.repoId,
    required this.depth,
  });

  final ImportedSession session;
  final String repoId;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedImportedSessionIdProvider) == session.id;
    final actions = ref.read(sessionActionsProvider);
    final cliLabel = session.cli == AgentKind.codex ? 'Codex' : 'Claude';

    Future<void> onMenu(String action) async {
      switch (action) {
        case 'resume':
          await _resume(context, actions, session);
        case 'rename':
          final name = await _promptRename(context, session.displayTitle);
          if (name != null) await actions.renameImported(session, name);
        case 'delete':
          if (await _confirmDelete(context, session.displayTitle, cli: true)) {
            await actions.deleteImported(session);
          }
      }
    }

    void select() {
      ref.read(selectedRepositoryIdProvider.notifier).select(repoId);
      ref.read(selectedSessionIdProvider.notifier).select(null);
      ref.read(selectedImportedSessionIdProvider.notifier).select(session.id);
    }

    return _SessionRow(
      depth: depth + (session.isSubagent ? 1 : 0),
      selected: selected,
      leading: Icon(
        session.isSubagent ? Icons.subdirectory_arrow_right : Icons.history,
        size: 16,
      ),
      title: session.displayTitle,
      subtitle: '$cliLabel · imported',
      onTap: select,
      menuItems: const [
        PopupMenuItem(value: 'resume', child: Text('Resume')),
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
      onMenu: onMenu,
    );
  }
}

/// Shared chrome for a session row: indented [ListTile] with selection, a
/// trailing menu button, and a right-click (secondary tap) context menu.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.depth,
    required this.selected,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.menuItems,
    required this.onMenu,
  });

  final int depth;
  final bool selected;
  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onMenu;

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: menuItems,
    );
    if (selected != null) onMenu(selected);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: ListTile(
        dense: true,
        selected: selected,
        contentPadding: EdgeInsets.only(left: 8.0 + depth * 16 + 36, right: 0),
        leading: leading,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          tooltip: 'Session actions',
          icon: const Icon(Icons.more_vert, size: 16),
          onSelected: onMenu,
          itemBuilder: (context) => menuItems,
        ),
        onTap: onTap,
      ),
    );
  }
}

Future<void> _resume(
  BuildContext context,
  SessionActions actions,
  ImportedSession session,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await actions.resumeImported(session);
    messenger.showSnackBar(const SnackBar(content: Text('Resuming session…')));
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(e is StateError ? e.message : '$e')),
    );
  }
}

Future<String?> _promptRename(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename session'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Title'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Rename'),
        ),
      ],
    ),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

Future<bool> _confirmDelete(
  BuildContext context,
  String title, {
  required bool cli,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete session?'),
      content: Text(
        cli
            ? 'Removes "$title" from the workspace and the CLI store.'
            : 'Permanently deletes "$title".',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  ).then((v) => v ?? false);
}
