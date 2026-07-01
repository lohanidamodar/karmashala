import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../agents/domain/agent_kind.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../cli_detection/presentation/detected_projects_view.dart';
import '../../editor/application/code_editor_providers.dart';
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
import '../../settings/application/settings_controller.dart';
import '../../sessions/domain/session_status.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';

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

  Future<void> _syncProject(Project project) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .syncSessions(project.id);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.sessions == 0
                ? 'Sessions are up to date.'
                : 'Added ${result.sessions} CLI session${result.sessions == 1 ? '' : 's'}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not refresh sessions: $error')),
      );
    }
  }

  void _toggleProject(Project project) {
    final expanding = !_expandedProjects.contains(project.id);
    setState(() {
      if (expanding) {
        _expandedProjects.add(project.id);
      } else {
        _expandedProjects.remove(project.id);
      }
    });
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    // Single-repository projects select that repository so "New session" and
    // the detail view have a working context immediately.
    final repos = ref.read(repositoryDaoProvider).getByProject(project.id);
    if (repos.length == 1) {
      ref.read(selectedRepositoryIdProvider.notifier).select(repos.first.id);
    }
    // Refresh live CLI sessions on expand so the newest ones surface without a
    // manual import. Quiet (no snackbar); the list updates via sessionsRevision.
    if (expanding) {
      ref.read(projectsControllerProvider.notifier).syncSessions(project.id);
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

  void _togglePin(Project project) {
    ref
        .read(settingsControllerProvider.notifier)
        .togglePinnedProject(project.id);
  }

  /// Opens the project's root folder in the configured code editor. When
  /// [chooseSubfolder] is set, a directory picker (rooted at the project) lets
  /// the user open a sub-folder instead.
  Future<void> _openProjectInEditor(
    Project project, {
    bool chooseSubfolder = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(editorActionsProvider);
    String? subPath;
    if (chooseSubfolder) {
      final picked = await getDirectoryPath(
        initialDirectory: actions.windowsRootPath(project),
        confirmButtonText: 'Open in editor',
      );
      if (picked == null) return;
      subPath = picked;
    }
    try {
      await actions.openProject(project.id, windowsSubPath: subPath);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Opening in editor…')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    }
  }

  Future<void> _confirmDeleteProject(Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.trash,
          title: 'Remove project?',
          subtitle: 'This only changes the Chitragupta workspace.',
        ),
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
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
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
    final allProjects = ref.watch(sortedProjectsProvider);
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
    final syncing = ref.watch(sessionSyncingProvider) > 0;

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
      icon: AppIcons.treeStructure,
      focused: focused,
      actions: [
        if (syncing)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        IconButton(
          tooltip: 'Detect CLI sessions',
          icon: const Icon(AppIcons.globe, size: 18),
          onPressed: _showDetected,
        ),
        IconButton(
          tooltip: selectedRepoId == null
              ? 'Select a repository first'
              : 'New session',
          icon: const Icon(AppIcons.chatCircleDots, size: 18),
          onPressed: selectedRepoId == null
              ? null
              : () => NewSessionDialog.show(context),
        ),
        IconButton(
          tooltip: 'New project',
          icon: const Icon(AppIcons.folderPlus, size: 18),
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
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: 18),
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
    final pinned = ref.watch(
      settingsControllerProvider.select((s) => s.isPinned(project.id)),
    );
    final expanded = _expandedProjects.contains(project.id);
    final rows = <Widget>[
      _TreeRow(
        depth: 0,
        selected: project.id == selectedProjectId,
        leading: Icon(
          expanded ? AppIcons.folderOpen : AppIcons.folder,
          size: 18,
        ),
        expandedState: expanded,
        title: project.name,
        subtitle: project.root.path,
        onTap: () => _toggleProject(project),
        menuItems: [
          DesktopMenuItem(
            value: 'new-session',
            label: 'New session',
            icon: AppIcons.chatCircleDots,
          ),
          DesktopMenuItem(
            value: 'copy-cmd',
            label: 'Copy new-session command',
            icon: AppIcons.copy,
          ),
          DesktopMenuItem(
            value: 'open-editor',
            label: 'Open in editor',
            icon: AppIcons.code,
          ),
          DesktopMenuItem(
            value: 'open-editor-subfolder',
            label: 'Open sub-folder in editor…',
            icon: AppIcons.folderOpen,
          ),
          DesktopMenuItem(
            value: 'pin',
            label: pinned ? 'Unpin' : 'Pin to top',
            icon: pinned ? AppIcons.pushPin : AppIcons.pushPin,
          ),
          DesktopMenuItem(
            value: 'refresh',
            label: 'Refresh CLI sessions',
            icon: AppIcons.arrowsClockwise,
          ),
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'delete',
            label: 'Remove from workspace',
            icon: AppIcons.trash,
            destructive: true,
          ),
        ],
        onMenu: (action) {
          if (action == 'new-session') _newSessionInProject(project);
          if (action == 'copy-cmd') {
            copyCommandToClipboard(
              context,
              () => ref
                  .read(sessionActionsProvider)
                  .newSessionShellCommand(project.id),
            );
          }
          if (action == 'open-editor') _openProjectInEditor(project);
          if (action == 'open-editor-subfolder') {
            _openProjectInEditor(project, chooseSubfolder: true);
          }
          if (action == 'pin') _togglePin(project);
          if (action == 'refresh') _syncProject(project);
          if (action == 'delete') _confirmDeleteProject(project);
        },
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pinned)
              IconButton(
                tooltip: 'Unpin',
                visualDensity: VisualDensity.compact,
                iconSize: 15,
                color: Theme.of(context).colorScheme.tertiary,
                icon: const Icon(AppIcons.pushPin),
                onPressed: () => _togglePin(project),
              ),
            IconButton(
              tooltip: 'New session in this project',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(AppIcons.plus),
              onPressed: () => _newSessionInProject(project),
            ),
            PopupMenuButton<String>(
              tooltip: 'Project actions',
              icon: const Icon(AppIcons.dotsThreeVertical, size: 16),
              onSelected: (action) {
                if (action == 'copy-cmd') {
                  copyCommandToClipboard(
                    context,
                    () => ref
                        .read(sessionActionsProvider)
                        .newSessionShellCommand(project.id),
                  );
                }
                if (action == 'open-editor') _openProjectInEditor(project);
                if (action == 'open-editor-subfolder') {
                  _openProjectInEditor(project, chooseSubfolder: true);
                }
                if (action == 'pin') _togglePin(project);
                if (action == 'refresh') _syncProject(project);
                if (action == 'delete') _confirmDeleteProject(project);
              },
              itemBuilder: (context) => [
                DesktopMenuItem(
                  value: 'copy-cmd',
                  label: 'Copy new-session command',
                  icon: AppIcons.copy,
                ),
                DesktopMenuItem(
                  value: 'open-editor',
                  label: 'Open in editor',
                  icon: AppIcons.code,
                ),
                DesktopMenuItem(
                  value: 'open-editor-subfolder',
                  label: 'Open sub-folder in editor…',
                  icon: AppIcons.folderOpen,
                ),
                DesktopMenuItem(
                  value: 'pin',
                  label: pinned ? 'Unpin' : 'Pin to top',
                  icon: pinned ? AppIcons.pushPin : AppIcons.pushPin,
                ),
                DesktopMenuItem(
                  value: 'refresh',
                  label: 'Refresh CLI sessions',
                  icon: AppIcons.arrowsClockwise,
                ),
                const DesktopMenuDivider(),
                DesktopMenuItem(
                  value: 'delete',
                  label: 'Remove from workspace',
                  icon: AppIcons.trash,
                  destructive: true,
                ),
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
        leading: const Icon(AppIcons.gitBranch, size: 16),
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
    final pinned = ref
        .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
        .toSet();

    // Merge native + imported sessions and order them: pinned first, then most
    // recently active. Native sessions sort by creation; imported by their CLI
    // store's last-updated time.
    final entries =
        <({DateTime ts, bool pinned, Widget row})>[
          for (final s in native)
            (
              ts: s.createdAt,
              pinned: pinned.contains(s.id),
              row: _NativeSessionRow(
                session: s,
                repoId: repo.id,
                depth: depth,
                pinned: pinned.contains(s.id),
              ),
            ),
          for (final s in imported)
            (
              ts: s.updatedAt ?? s.createdAt,
              pinned: pinned.contains(s.id),
              row: _ImportedSessionRow(
                session: s,
                repoId: repo.id,
                depth: depth,
                pinned: pinned.contains(s.id),
              ),
            ),
        ]..sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          return b.ts.compareTo(a.ts);
        });
    return [for (final e in entries) e.row];
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
    this.menuItems,
    this.onMenu,
  });

  final int depth;
  final bool selected;
  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final List<PopupMenuEntry<String>>? menuItems;
  final ValueChanged<String>? onMenu;

  /// When non-null, a disclosure chevron reflecting expansion state is shown.
  final bool? expandedState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tile = ListTile(
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
                expandedState! ? AppIcons.caretDown : AppIcons.caretRight,
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
      title: Row(
        children: [
          Flexible(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 7),
            Expanded(
              child: Tooltip(
                message: subtitle!,
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                ),
              ),
            ),
          ],
        ],
      ),
      trailing: trailing,
      onTap: onTap,
    );
    if (menuItems == null || onMenu == null) return tile;
    return _ContextMenuRegion(
      menuItems: menuItems!,
      onSelected: onMenu!,
      child: tile,
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
    this.pinned = false,
  });

  final Session session;
  final String repoId;
  final int depth;
  final bool pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSessionIdProvider) == session.id;
    final actions = ref.read(sessionActionsProvider);
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];

    Future<void> rename() async {
      final name = await _promptRename(context, session.title);
      if (name != null) actions.renameNative(session.id, name);
    }

    Future<void> delete() async {
      final deleteFromCli = await _confirmDelete(context, session.title);
      if (deleteFromCli == null) return;
      try {
        await actions.deleteNative(session.id, deleteFromCli: deleteFromCli);
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error is StateError ? error.message : '$error'),
          ),
        );
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
      pinned: pinned,
      leading: _statusIcon(session.status, context),
      title: session.title,
      subtitle:
          '${session.status.name}'
          '${session.useWorktree ? ' · worktree' : ''}',
      onTap: select,
      menuItems: [
        for (final terminal in terminals)
          DesktopMenuItem(
            value: 'terminal:${terminal.id}',
            label: 'Open in ${terminal.label}',
            icon: AppIcons.terminal,
          ),
        if (terminals.isNotEmpty) const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'pin',
          label: pinned ? 'Unpin' : 'Pin to top',
          icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
        ),
        DesktopMenuItem(
          value: 'copy-cmd',
          label: 'Copy resume command',
          icon: AppIcons.copy,
        ),
        DesktopMenuItem(
          value: 'rename',
          label: 'Rename',
          icon: AppIcons.pencilSimple,
          shortcut: 'F2',
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'delete',
          label: 'Delete',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
      onMenu: (action) async {
        if (action.startsWith('terminal:')) {
          final id = action.substring('terminal:'.length);
          final terminal = terminals.where((t) => t.id == id).firstOrNull;
          if (terminal != null) {
            await _openNativeInTerminal(context, actions, session, terminal);
          }
          return;
        }
        switch (action) {
          case 'pin':
            ref
                .read(settingsControllerProvider.notifier)
                .togglePinnedSession(session.id);
          case 'copy-cmd':
            copyCommandToClipboard(
              context,
              () => actions.nativeResumeShellCommand(session.id),
            );
          case 'rename':
            rename();
          case 'delete':
            delete();
        }
      },
    );
  }

  Widget _statusIcon(SessionStatus status, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (status) {
      SessionStatus.running => (AppIcons.playCircle, scheme.tertiary),
      SessionStatus.completed => (AppIcons.checkCircle, Colors.green),
      SessionStatus.failed => (AppIcons.warningCircle, scheme.error),
      SessionStatus.cancelled => (AppIcons.xCircle, scheme.outline),
      _ => (AppIcons.circle, scheme.outline),
    };
    return Icon(icon, size: 16, color: color);
  }
}

class _ImportedSessionRow extends ConsumerWidget {
  const _ImportedSessionRow({
    required this.session,
    required this.repoId,
    required this.depth,
    this.pinned = false,
  });

  final ImportedSession session;
  final String repoId;
  final int depth;
  final bool pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedImportedSessionIdProvider) == session.id;
    final actions = ref.read(sessionActionsProvider);
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    final cliLabel = session.cli == AgentKind.codex ? 'Codex' : 'Claude';

    Future<void> onMenu(String action) async {
      switch (action) {
        case final value when value.startsWith('terminal:'):
          final id = value.substring('terminal:'.length);
          final terminal = terminals.where((t) => t.id == id).firstOrNull;
          if (terminal != null) {
            await _openImportedInTerminal(context, actions, session, terminal);
          }
        case 'pin':
          ref
              .read(settingsControllerProvider.notifier)
              .togglePinnedSession(session.id);
        case 'resume':
          await _resume(context, actions, session);
        case 'copy-cmd':
          copyCommandToClipboard(
            context,
            () => actions.resumeShellCommand(session),
          );
        case 'rename':
          final name = await _promptRename(context, session.displayTitle);
          if (name != null) await actions.renameImported(session, name);
        case 'delete':
          final deleteFromCli = await _confirmDelete(
            context,
            session.displayTitle,
          );
          if (deleteFromCli != null) {
            await actions.deleteImported(session, deleteFromCli: deleteFromCli);
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
      pinned: pinned,
      leading: Icon(
        session.isSubagent
            ? AppIcons.arrowBendDownRight
            : AppIcons.clockCounterClockwise,
        size: 16,
      ),
      title: session.displayTitle,
      subtitle: '$cliLabel · imported',
      onTap: select,
      menuItems: [
        DesktopMenuItem(
          value: 'resume',
          label: 'Resume in app',
          icon: AppIcons.play,
        ),
        for (final terminal in terminals)
          DesktopMenuItem(
            value: 'terminal:${terminal.id}',
            label: 'Open in ${terminal.label}',
            icon: AppIcons.terminal,
          ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'pin',
          label: pinned ? 'Unpin' : 'Pin to top',
          icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
        ),
        DesktopMenuItem(
          value: 'copy-cmd',
          label: 'Copy resume command',
          icon: AppIcons.copy,
        ),
        DesktopMenuItem(
          value: 'rename',
          label: 'Rename',
          icon: AppIcons.pencilSimple,
          shortcut: 'F2',
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'delete',
          label: 'Delete from CLI store',
          icon: AppIcons.trash,
          destructive: true,
        ),
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
    this.pinned = false,
  });

  final int depth;
  final bool selected;
  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onMenu;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    return _ContextMenuRegion(
      menuItems: menuItems,
      onSelected: onMenu,
      child: ListTile(
        dense: true,
        selected: selected,
        contentPadding: EdgeInsets.only(left: 8.0 + depth * 16 + 36, right: 0),
        leading: leading,
        title: Row(
          children: [
            if (pinned) ...[
              Icon(
                AppIcons.pushPinFill,
                size: 11,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: subtitle,
              child: Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontSize: 10),
              ),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          tooltip: 'Session actions',
          icon: const Icon(AppIcons.dotsThreeVertical, size: 16),
          onSelected: onMenu,
          itemBuilder: (context) => menuItems,
        ),
        onTap: onTap,
      ),
    );
  }
}

class _ContextMenuRegion extends StatelessWidget {
  const _ContextMenuRegion({
    required this.menuItems,
    required this.onSelected,
    required this.child,
  });

  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onSelected;
  final Widget child;

  Future<void> _show(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: menuItems,
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapDown: (details) => _show(context, details.globalPosition),
    child: child,
  );
}

Future<void> _openNativeInTerminal(
  BuildContext context,
  SessionActions actions,
  Session session,
  SystemTerminal terminal,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await actions.openSessionInSystemTerminal(session.id, terminal);
    messenger.showSnackBar(
      SnackBar(content: Text('Opening in ${terminal.label}…')),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(error is StateError ? error.message : '$error')),
    );
  }
}

Future<void> _openImportedInTerminal(
  BuildContext context,
  SessionActions actions,
  ImportedSession session,
  SystemTerminal terminal,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await actions.openInSystemTerminal(session, terminal);
    messenger.showSnackBar(
      SnackBar(content: Text('Opening in ${terminal.label}…')),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(error is StateError ? error.message : '$error')),
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

/// Builds a shell command with [build], copies it to the clipboard, and reports
/// the result. Used by the "Copy … command" menu actions.
Future<void> copyCommandToClipboard(
  BuildContext context,
  String Function() build,
) async {
  final messenger = ScaffoldMessenger.of(context);
  String message;
  try {
    await Clipboard.setData(ClipboardData(text: build()));
    message = 'Command copied to clipboard';
  } catch (e) {
    message = e is StateError ? e.message : '$e';
  }
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

Future<String?> _promptRename(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.pencilSimple,
        title: 'Rename session',
      ),
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

Future<bool?> _confirmDelete(BuildContext context, String title) {
  var deleteFromCli = true;
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.trash,
          title: 'Delete session?',
          subtitle: 'Choose whether to also remove the CLI history.',
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Remove "$title" from Chitragupta.'),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: deleteFromCli,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Also delete from the CLI store'),
                subtitle: const Text(
                  'Checked by default. This removes the original transcript.',
                ),
                onChanged: (value) =>
                    setState(() => deleteFromCli = value ?? true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(deleteFromCli),
            child: const Text('Delete'),
          ),
        ],
      ),
    ),
  );
}
