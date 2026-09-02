import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/shell/shell_state.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_registry.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../cli_detection/presentation/detected_projects_view.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../application/checkout.dart';
import '../application/explorer_actions.dart';
import '../application/project_tree.dart';
import '../application/session_diff_stat.dart';
import '../application/session_forest.dart';
import 'explorer_row.dart';
import 'project_card.dart';
import 'session_card.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/presentation/continue_with_dialog.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/presentation/agent_status_badge.dart';
import '../../sessions/application/session_resume_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/domain/session.dart';
import '../../settings/application/settings_controller.dart';
import '../../sessions/domain/session_lineage.dart';
import '../../sessions/domain/session_resume.dart';
import '../../sessions/domain/session_status.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';

/// The unified left pane: **Project → Session**, and deliberately nothing else.
///
/// Loop 58 made this Project → Repository → Worktree → Session, to answer
/// *which of these twelve clones is that agent working in?* It answered it in
/// the wrong place. A `project_rescan` of the owner's hub recorded **69**
/// checkouts — a dozen sibling clones and ~25 `wt-*` worktrees — and the tree
/// dutifully drew a row for each, every row watching a per-checkout git
/// provider: **six git subprocesses per recorded checkout**, 414 of them to
/// draw thirteen visible rows, repeated on every workspace mutation, each on a
/// WSL path reached over 9p at 1.19 ms a stat. That is the freeze the owner
/// reported. `test/features/explorer/checkout_scale_cost_test.dart` is the
/// measurement.
///
/// The question was good; the surface was wrong. *Which checkout is this agent
/// in* is a question about the session you are looking at, so it is answered
/// where that session is already the subject — the right sidebar's Changes,
/// GitHub and Repository surfaces, from [projectCheckoutsProvider]. The
/// Explorer lists sessions, and a session's own card still carries the
/// sub-path it works in.
///
/// **What it costs to open a project.** Two indexed DAO reads. No git at all:
/// there is no longer a row here that describes a checkout, so there is
/// nothing here to ask git about. What a session card costs is charged when
/// that card is *inflated*, because [_NativeSessionRow] and
/// [_ImportedSessionRow] are `ConsumerWidget`s that watch inside their own
/// `build` — which is the distinction the old checkout rows got wrong, since
/// they watched during the panel's own build and so paid for every row the
/// list would never show.
class ExplorerPanel extends ConsumerStatefulWidget {
  const ExplorerPanel({super.key});

  @override
  ConsumerState<ExplorerPanel> createState() => _ExplorerPanelState();
}

class _ExplorerPanelState extends ConsumerState<ExplorerPanel> {
  String _query = '';
  final Set<String> _expandedProjects = {};

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

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _syncProject(Project project) async {
    try {
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .syncSessions(project.id);
      _say(
        result.sessions == 0
            ? 'Sessions are up to date.'
            : 'Added ${result.sessions} CLI session${result.sessions == 1 ? '' : 's'}.',
      );
    } catch (error) {
      _say('Could not refresh sessions: $error');
    }
  }

  /// Re-runs discovery over the project's folder, which is what turns a "not
  /// scanned yet" row into a real repository row.
  Future<void> _rescan(Project project) async {
    try {
      final added = await ref
          .read(projectsControllerProvider.notifier)
          .rediscover(project.id);
      _say(
        added.isEmpty
            ? 'No new repositories found in ${project.name}.'
            : 'Found ${added.length} '
                  'repositor${added.length == 1 ? 'y' : 'ies'}.',
      );
    } catch (error) {
      _say(error is StateError ? error.message : 'Could not rescan: $error');
    }
  }

  /// Opens [path] in the host's file manager and says why when it cannot.
  ///
  /// [RevealInFileManager.reveal] reports its two real failures — no file
  /// manager, and a path with no host spelling — as a [RevealOutcome] rather
  /// than a throw, so a `catch` here would never fire and the click would be
  /// silent. The menu entry is hidden on rows that cannot be revealed
  /// ([_pathMenuItems]); this covers the ones that fail anyway, such as a file
  /// manager that will not start.
  Future<void> _reveal(EnvironmentPath path) async {
    final outcome = await ref.read(revealInFileManagerProvider).reveal(path);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _copyPath(EnvironmentPath path) async {
    await Clipboard.setData(ClipboardData(text: path.path));
    _say('Path copied to clipboard');
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

  /// Starts a session in one click. [installation] is the "…with" choice; left
  /// out, the configured default agent for that environment is used.
  Future<void> _startSession({
    required Repository repository,
    EnvironmentPath? existingWorktree,
    AgentInstallation? installation,
  }) async {
    final result = await ref
        .read(explorerActionsProvider)
        .startSession(
          repository: repository,
          existingWorktree: existingWorktree,
          installation: installation,
        );
    final message = result.message;
    if (message != null) _say(message);
  }

  /// The dialog path — a title, an agent, a worktree, an external terminal.
  void _newSessionDialog(Project project, {Repository? repository}) {
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    setState(() => _expandedProjects.add(project.id));
    final repo =
        repository ??
        ref.read(repositoryDaoProvider).getByProject(project.id).firstOrNull;
    if (repo == null) {
      _say('This project has no Git repositories to run in.');
      return;
    }
    ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
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
      _say('Opening in editor…');
    } catch (e) {
      _say(e is StateError ? e.message : '$e');
    }
  }

  Future<void> _confirmDeleteProject(Project project) async {
    var deleteCliSessions = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const DesktopDialogTitle(
            icon: AppIcons.trash,
            title: 'Remove project?',
            subtitle: 'This only changes the Karmashala workspace.',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Removes "${project.name}" and all its sessions from the '
                'workspace.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: deleteCliSessions,
                onChanged: (v) =>
                    setState(() => deleteCliSessions = v ?? false),
                title: const Text('Also delete session files on disk'),
                subtitle: const Text(
                  "Permanently removes this project's Claude/Codex session "
                  'history from the CLI store. Otherwise, files on disk are '
                  'left untouched.',
                ),
              ),
            ],
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
      ),
    );
    if (ok ?? false) {
      await ref
          .read(projectsControllerProvider.notifier)
          .deleteProject(project.id, deleteCliSessions: deleteCliSessions);
    }
  }

  @override
  Widget build(BuildContext context) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.explorer;
    final allProjects = ref.watch(sortedProjectsProvider);
    // Re-read sessions whenever the workspace mutates. Not on a permission
    // mode: the panel draws none, and its children each narrow further.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.title,
      SessionChangeKind.status,
      SessionChangeKind.placement,
      SessionChangeKind.workspace,
    });

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
        // The same gap the rows put between themselves, above the first and
        // below the last, so the column has one rhythm from end to end.
        padding: const EdgeInsets.symmetric(vertical: ExplorerRow.gap),
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
          // Not `globe`, which is the Browser surface's glyph (Loop 56 found
          // the collision and left it here). Finding conversations an agent
          // already wrote is history, and the imported cards use this glyph for
          // exactly that.
          icon: const Icon(AppIcons.clockCounterClockwise, size: 18),
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
              // Inset to the row tiles' own edges: the field and the rows
              // beneath it are one column, not two things that nearly line up.
              padding: const EdgeInsets.fromLTRB(
                Insets.xs,
                Insets.sm,
                Insets.xs,
                Insets.xs,
              ),
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

  // --- rows ------------------------------------------------------------------

  /// The rows for one project: its card, then (when expanded) its tree.
  List<Widget> _projectNodes(Project project) {
    final selectedProjectId = ref.watch(selectedProjectIdProvider);
    final pinned = ref.watch(
      settingsControllerProvider.select((s) => s.isPinned(project.id)),
    );
    final expanded = _expandedProjects.contains(project.id);
    final missing =
        ref.watch(projectPathMissingProvider(project)).asData?.value ?? false;
    // Sessions are counted from the database; changed files are whatever the
    // per-checkout providers have already answered, so a header never starts a
    // second wave of git.
    final summary = ref.watch(projectSummaryProvider(project.id));

    final rows = <Widget>[
      ProjectCard(
        name: project.name,
        path: project.root.path,
        expanded: expanded,
        selected: project.id == selectedProjectId,
        missing: missing,
        pinned: pinned,
        summary: summary,
        onTap: () => _toggleProject(project),
        onNewSession: () => _newSessionDialog(project),
        onTogglePin: () => _togglePin(project),
        menuItems: [
          DesktopMenuItem(
            value: 'new-session',
            label: 'New session…',
            icon: AppIcons.chatCircleDots,
          ),
          ..._agentMenuItems(project.root.environmentId),
          DesktopMenuItem(
            value: 'copy-cmd',
            label: 'Copy new-session command',
            icon: AppIcons.copy,
          ),
          const DesktopMenuDivider(),
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
          ..._pathMenuItems(project.root),
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'pin',
            label: pinned ? 'Unpin' : 'Pin to top',
            icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
          ),
          DesktopMenuItem(
            value: 'refresh',
            label: 'Refresh CLI sessions',
            icon: AppIcons.arrowsClockwise,
          ),
          DesktopMenuItem(
            value: 'rescan',
            label: 'Rescan for repositories',
            icon: AppIcons.magnifyingGlass,
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
          final installation = _installationFromMenu(
            action,
            project.root.environmentId,
          );
          if (installation != null) {
            final repo = ref
                .read(repositoryDaoProvider)
                .getByProject(project.id)
                .firstOrNull;
            if (repo == null) {
              _say('This project has no Git repositories to run in.');
            } else {
              _startSession(repository: repo, installation: installation);
            }
            return;
          }
          switch (action) {
            case 'new-session':
              _newSessionDialog(project);
            case 'copy-cmd':
              copyCommandToClipboard(
                context,
                () => ref
                    .read(sessionActionsProvider)
                    .newSessionShellCommand(project.id),
              );
            case 'open-editor':
              _openProjectInEditor(project);
            case 'open-editor-subfolder':
              _openProjectInEditor(project, chooseSubfolder: true);
            case 'reveal':
              _reveal(project.root);
            case 'copy-path':
              _copyPath(project.root);
            case 'pin':
              _togglePin(project);
            case 'refresh':
              _syncProject(project);
            case 'rescan':
              _rescan(project);
            case 'delete':
              _confirmDeleteProject(project);
          }
        },
      ),
    ];
    if (!expanded) return rows;

    // Two indexed DAO reads, and no git at any depth: the checkouts a session
    // works in are the right sidebar's subject now, not a row here.
    final sessions = ref.watch(projectSessionsProvider(project.id));
    if (sessions.isEmpty) {
      rows.add(
        const _TreeHint(
          depth: 1,
          message: 'No sessions yet — start one with the + on this project.',
        ),
      );
      return rows;
    }
    rows.addAll(_sessionCards(project, sessions, depth: 1));
    return rows;
  }

  /// The cards on one row: native sessions arranged parent-and-child, imported
  /// conversations interleaved by when they were last touched.
  List<Widget> _sessionCards(
    Project project,
    CheckoutSessions sessions, {
    required int depth,
  }) {
    if (sessions.isEmpty) return const [];
    final pinnedIds = ref
        .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
        .toSet();
    final forest = buildSessionForest(
      sessions.native,
      isPinned: pinnedIds.contains,
    );

    // Pinned first, then most recently active — the ordering the flat list
    // always had, now applied to the *top* of each lineage so a child never
    // floats above the session it came from.
    final entries =
        <({DateTime ts, bool pinned, List<Widget> rows})>[
          for (final node in forest)
            (
              ts: node.session.createdAt,
              pinned: pinnedIds.contains(node.session.id),
              rows: _lineageRows(project, node, depth: depth, parent: null),
            ),
          for (final imported in sessions.imported)
            (
              ts: imported.updatedAt ?? imported.createdAt,
              pinned: pinnedIds.contains(imported.id),
              rows: [
                _ImportedSessionRow(
                  session: imported,
                  depth: depth + (imported.isSubagent ? 1 : 0),
                  subPath: _subPathForImported(project, imported),
                  pinned: pinnedIds.contains(imported.id),
                ),
              ],
            ),
        ]..sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          return b.ts.compareTo(a.ts);
        });
    return [for (final entry in entries) ...entry.rows];
  }

  List<Widget> _lineageRows(
    Project project,
    SessionNode node, {
    required int depth,
    required Session? parent,
  }) => [
    _NativeSessionRow(
      session: node.session,
      depth: depth,
      subPath: _subPathForNative(project, node.session),
      pinned: ref
          .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
          .contains(node.session.id),
      link: node.link,
      parentTitle: parent?.title,
      lineageBroken: node.lineageBroken,
    ),
    for (final child in node.children)
      ..._lineageRows(project, child, depth: depth + 1, parent: node.session),
  ];

  // --- shared menu fragments --------------------------------------------------

  /// `New session with <agent>` for every agent installed where the row lives.
  ///
  /// Only offered when there is a choice to make: with one installation the `+`
  /// already uses it, and a menu item that repeats a button teaches nothing.
  List<PopupMenuEntry<String>> _agentMenuItems(String environmentId) {
    final installations = ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(environmentId);
    if (installations.length < 2) return const [];
    return [
      for (final installation in installations)
        DesktopMenuItem(
          value: 'new-with:${installation.id}',
          label:
              'New session with '
              '${AgentRegistry.builtIn.displayNameFor(installation.agentId)}',
          icon: AppIcons.robot,
        ),
    ];
  }

  AgentInstallation? _installationFromMenu(
    String action,
    String environmentId,
  ) {
    if (!action.startsWith('new-with:')) return null;
    final id = action.substring('new-with:'.length);
    return ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(environmentId)
        .where((installation) => installation.id == id)
        .firstOrNull;
  }

  /// The path items a folder row carries. "Copy path" always works — it is
  /// text. "Open in File Explorer" is offered only where the host can actually
  /// reach [path]: an SSH-owned row has no local spelling at all, and an entry
  /// that always fails is worse than no entry. [RevealInFileManager.canReveal]
  /// starts no process, so asking it while building a menu is free.
  List<PopupMenuEntry<String>> _pathMenuItems(EnvironmentPath path) => [
    const DesktopMenuDivider(),
    if (ref.read(revealInFileManagerProvider).canReveal(path))
      DesktopMenuItem(
        value: 'reveal',
        label: 'Open in File Explorer',
        icon: AppIcons.folderOpen,
      ),
    DesktopMenuItem(
      value: 'copy-path',
      label: 'Copy path',
      icon: AppIcons.copySimple,
    ),
  ];

  // --- paths ------------------------------------------------------------------

  String? _subPathForNative(Project project, Session session) {
    final directory =
        session.worktree ??
        ref.read(repositoryDaoProvider).getById(session.repositoryId)?.path;
    return directory == null ? null : relativeSubPath(project.root, directory);
  }

  String? _subPathForImported(Project project, ImportedSession session) {
    final path = ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId)
        ?.path;
    return path == null ? null : relativeSubPath(project.root, path);
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
      // Lined up with the text of a row at the same depth, so the hint reads as
      // sitting inside the node it is about rather than beside it.
      padding: EdgeInsets.fromLTRB(
        Insets.xs + depth * ExplorerRow.indent + Insets.lg,
        Insets.xs,
        Insets.sm,
        Insets.sm,
      ),
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
    required this.depth,
    this.subPath,
    this.pinned = false,
    this.link,
    this.parentTitle,
    this.lineageBroken = false,
  });

  final Session session;
  final int depth;
  final String? subPath;
  final bool pinned;
  final SessionLink? link;
  final String? parentTitle;
  final bool lineageBroken;

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

    // One click opens the session: a pane of ours that is still running comes
    // back, a stopped conversation is resumed — in its own worktree when it has
    // one — and an agent that will not share says so in plain words.
    Future<void> open() async {
      final messenger = ScaffoldMessenger.of(context);
      final result = await ref
          .read(explorerActionsProvider)
          .openNative(session.id);
      final message = result.message;
      if (message == null) return;
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }

    // What we can honestly say about where this session's process is, before
    // the user clicks anything. Three separately-weighted facts, none of which
    // is allowed to become a confident "active": see [SessionWhereabouts].
    final whereabouts = ref.watch(sessionWhereaboutsProvider(session.id));
    // The newest evidence the agent itself produced, or failing that when the
    // session was created. Never the time of our last poll: ageing a poll would
    // make a week-old transcript look live.
    final now = ref.read(clockProvider).nowUtc();
    final since = whereabouts.lastSeen ?? session.createdAt;
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final (statusIcon, statusColor) = _status(session.status, context);
    // Asynchronous by construction: the card renders without it and fills in
    // when git answers. Keyed by session, deduplicated by checkout.
    final stat = ref.watch(sessionDiffStatProvider(session.id)).asData?.value;

    return SessionCard(
      depth: depth,
      selected: selected,
      pinned: pinned,
      agentIcon: statusIcon,
      agentColor: statusColor,
      agentLabel: [
        agentId == null
            ? 'Agent'
            : AgentRegistry.builtIn.displayNameFor(agentId),
        session.status.name,
      ].join('  ·  '),
      // Two different things, deliberately both shown: the badge is what the
      // agent is doing *now* (from a hook, its transcript, or its screen) and
      // the word beside its name is the session's own lifecycle. A session can
      // be `running` and its agent idle, waiting for you to type.
      badge: AgentStatusBadge(sessionId: session.id),
      age: compactAge(now.difference(since)),
      // The corner has room for a number, not for how much to trust it. Loop
      // 46's exact wording survives on hover, including the distinction
      // between evidence the agent produced and the row's own birthday.
      ageTooltip:
          whereabouts.lastSeenLabel(now) ??
          'Created ${describeAge(now.difference(session.createdAt))}',
      title: session.title,
      branch: stat?.branch,
      subPath: subPath,
      whereabouts: whereabouts.note,
      whereaboutsTooltip: whereabouts.explanation,
      stat: stat,
      worktree: session.useWorktree,
      link: link,
      parentTitle: parentTitle,
      lineageBroken: lineageBroken,
      onTap: open,
      menuItems: [
        // Moving a session to another agent, or branching it, belongs on the
        // session — not only on the delivery strip, which is the one place it
        // used to live and is only reachable while a session is on screen.
        DesktopMenuItem(
          value: 'continue-with',
          label: 'Continue with…',
          icon: AppIcons.gitBranch,
        ),
        // One entry, not one per installed terminal. Three of the eight items
        // in this menu used to be external-terminal openers, which is a lot of
        // room for something the owner does not reach for; the default
        // terminal is the answer in almost every case, and the rest is a
        // setting rather than a menu.
        if (terminals.isNotEmpty)
          DesktopMenuItem(
            value: 'terminal:${terminals.first.id}',
            label: 'Open in system terminal',
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
          case 'continue-with':
            // The dialog owns every decision here — which agent, handoff or
            // fork, and what permission mode the session lands in — and it
            // launches nothing until the user has seen the packet. So this is
            // a route to it, not a second place that reasons about any of it.
            await ContinueWithDialog.show(context, session.id);
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

  /// The session's lifecycle, as a glyph and a semantic colour. Returned as a
  /// record rather than a widget because the card draws it at its own size.
  (IconData, Color) _status(SessionStatus status, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    return switch (status) {
      SessionStatus.running => (AppIcons.playCircle, semantic.working),
      SessionStatus.completed => (AppIcons.checkCircle, semantic.idle),
      SessionStatus.failed => (AppIcons.warningCircle, semantic.failure),
      SessionStatus.cancelled => (AppIcons.xCircle, scheme.outline),
      _ => (AppIcons.circle, scheme.outline),
    };
  }
}

class _ImportedSessionRow extends ConsumerWidget {
  const _ImportedSessionRow({
    required this.session,
    required this.depth,
    this.subPath,
    this.pinned = false,
  });

  final ImportedSession session;
  final int depth;
  final String? subPath;
  final bool pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedImportedSessionIdProvider) == session.id;
    final actions = ref.read(sessionActionsProvider);
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    final cliLabel = AgentRegistry.builtIn.displayNameFor(session.cli);
    // The CLI store file's own mtime — the strongest "last seen" anywhere in the
    // app, because it is the agent's own writing rather than anything we
    // inferred. Aged rather than stated, so a row can never claim to be live.
    final updatedAt = session.updatedAt;
    final lastSeen = updatedAt == null
        ? null
        : compactAge(ref.read(clockProvider).nowUtc().difference(updatedAt));

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
          await _open(context, ref, session);
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

    final stat = ref
        .watch(repositoryDiffStatProvider(session.repositoryId))
        .asData
        ?.value;

    return SessionCard(
      depth: depth,
      selected: selected,
      pinned: pinned,
      agentIcon: session.isSubagent
          ? AppIcons.arrowBendDownRight
          : AppIcons.clockCounterClockwise,
      agentLabel: [cliLabel, 'imported'].join('  ·  '),
      age: lastSeen,
      ageTooltip: lastSeen == null
          ? null
          : 'The agent last wrote to this conversation then. We cannot see '
                'whether a process still has it open.',
      title: session.displayTitle,
      branch: stat?.branch,
      subPath: subPath,
      stat: stat,
      onTap: () => _open(context, ref, session),
      menuItems: [
        DesktopMenuItem(
          value: 'resume',
          // "in app" was distinguishing it from the three external-terminal
          // openers below it. With those collapsed to one, the qualifier is
          // noise: resuming is what this app does.
          label: 'Resume',
          icon: AppIcons.play,
        ),
        if (terminals.isNotEmpty)
          DesktopMenuItem(
            value: 'terminal:${terminals.first.id}',
            label: 'Open in system terminal',
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

Future<void> _open(
  BuildContext context,
  WidgetRef ref,
  ImportedSession session,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await ref.read(explorerActionsProvider).openImported(session);
  final message = result.message;
  if (message != null) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
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
              Text('Remove "$title" from Karmashala.'),
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
