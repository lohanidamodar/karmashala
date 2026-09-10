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
import '../../../core/util/clock_provider.dart';
import '../../../core/util/file_picking.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import '../../cli_detection/presentation/detected_projects_view.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_last_active_providers.dart';
import 'package:karmashala_session/resume.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_git/repositories.dart';
import '../application/checkout.dart';
import '../application/explorer_actions.dart';
import '../application/explorer_agent_filter.dart';
import '../domain/agent_filter.dart';
import '../application/project_tree.dart';
import '../application/session_diff_stat.dart';
import '../application/checkout_picker.dart';
import '../application/session_forest.dart';
import '../application/session_selection.dart';
import 'explorer_row.dart';
import 'project_card.dart';
import '../application/explorer_sections.dart';
import 'explorer_sections_view.dart';
import 'session_rows.dart';
import 'session_selection_bar.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../../workspaces/domain/workspace.dart';
import '../../workspaces/presentation/new_context_dialog.dart';
import '../../workspaces/presentation/workspace_scope_bar.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_defaults.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import '../../settings/application/settings_controller.dart';
import '../../sessions/presentation/new_session_dialog.dart';

/// Prefix on a "put this project in a context" menu value, so one `startsWith`
/// tells it from the row's other verbs — the shape `new-with:` uses for agents.
const _contextAction = 'context:';

/// The two choices in that list that are not a context id. Neither can collide
/// with one: an id is generated, and these are spelled without the prefix.
const _noContext = 'none';
const _newContext = 'new';

/// What a project row's menu needs, resolved once by [ExplorerPanel]'s build:
/// menus are built eagerly per row, so a per-row DAO read is one query a row.
typedef _RowMenuFacts = ({
  List<Workspace> workspaces,
  Map<String, int> counts,
  Map<String, List<AgentInstallation>> installations,
});

/// The unified left pane: Project → Session, and deliberately nothing else;
/// checkout rows were removed for their git cost (`checkout_scale_cost_test`).
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

  /// " · checked 3m ago", or " · never checked" when nothing has read the
  /// stores for this project yet.
  String _checkedSuffix(String projectId) {
    final at = ref.read(cliSessionsCheckedProvider).forProject(projectId);
    if (at == null) return ' · never checked';
    final now = ref.read(clockProvider).nowUtc();
    return ' · checked ${describeAge(now.difference(at))}';
  }

  void _openTerminal(Project project) {
    final envDao = ref.read(executionEnvironmentDaoProvider);
    final env = envDao.getById(project.environmentId);
    final sshHostId = env?.sshHostId;
    if (sshHostId != null) {
      ref.read(terminalSessionsControllerProvider.notifier).openTab(
            TerminalProfile.ssh(
              sshHostId,
              hostName: env?.name,
            ),
            workingDirectory: project.root.path,
          );
    } else if (env?.kind == EnvironmentKind.wsl) {
      final distro = env?.wslDistribution ?? env?.name ?? '';
      ref.read(terminalSessionsControllerProvider.notifier).openTab(
            TerminalProfile(
              id: TerminalProfile.wslId(distro),
              label: '$distro (WSL)',
              shell: TerminalShell.wsl,
              wslDistribution: distro,
            ),
            workingDirectory: project.root.path,
          );
    } else {
      ref.read(terminalSessionsControllerProvider.notifier).openTab(
            TerminalProfile.powerShell,
            workingDirectory: project.root.path,
          );
    }
    ref.read(terminalSessionsControllerProvider.notifier).showTerminalHere();
  }

  /// Opens [path] in the host's file manager. [RevealInFileManager.reveal]
  /// reports its failures as a [RevealOutcome], never a throw, so no `catch`.
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
    // Nothing is scanned here: expanding used to start a full walk of every CLI
    // store. `explorer_expand_scan_cost_test.dart` pins the zero.
  }

  /// Starts a session in one click; [installation] left out means the
  /// configured default agent for that environment.
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

  /// Where a session started *at the project* runs — the first checkout the
  /// picker would offer, so the `+` and the dialog cannot pick different clones.
  Repository? _defaultCheckoutOf(Project project) =>
      ref.read(checkoutsInProjectProvider(project.id)).firstOrNull ??
      ref.read(repositoryDaoProvider).getByProject(project.id).firstOrNull;

  /// The `+` on a project row: starts a session with [SessionDefaults] and no
  /// dialog — unless a piece is missing, when the dialog opens to name it.
  Future<void> _startWithDefaults(Project project) async {
    final repository = _defaultCheckoutOf(project);
    final defaults = repository == null
        ? null
        : ref.read(sessionDefaultsProvider).forCheckout(repository);
    if (defaults == null || !defaults.isComplete) {
      _newSessionDialog(project, repository: repository);
      return;
    }
    // The card the session appears on has to be on screen: a start nobody can
    // see is indistinguishable from a dead click.
    if (ref.read(selectedProjectIdProvider) != project.id) {
      ref.read(selectedProjectIdProvider.notifier).select(project.id);
    }
    setState(() => _expandedProjects.add(project.id));
    await _startSession(
      repository: repository!,
      installation: defaults.installation,
    );
  }

  /// The dialog path — a title, a destination, an agent, a worktree, an
  /// external terminal.
  void _newSessionDialog(Project project, {Repository? repository}) {
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    setState(() => _expandedProjects.add(project.id));
    final repo = repository ?? _defaultCheckoutOf(project);
    if (repo == null) {
        // Still a refusal: the dialog opens on the current selection, so opening
        // it here would point it at whichever other project was last selected.
      _say('This project has no Git repositories to run in.');
      return;
    }
    // The dialog opens on the selection, so this is what points it at the
    // project whose row was clicked.
    ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
    NewSessionDialog.show(context);
  }

  void _togglePin(Project project) {
    ref
        .read(settingsControllerProvider.notifier)
        .togglePinnedProject(project.id);
  }

  /// With [chooseSubfolder], a picker rooted at the project chooses a
  /// sub-folder to open instead of the project root.
  Future<void> _openProjectInEditor(
    Project project, {
    bool chooseSubfolder = false,
  }) async {
    final actions = ref.read(editorActionsProvider);
    String? subPath;
    if (chooseSubfolder) {
      final picked = await pickOneDirectory(
        what: 'a folder of ${project.name} to open',
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
    final scoped = ref.watch(workspaceScopedProjectsProvider);
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
        ? scoped
        : scoped
              .where(
                (p) =>
                    p.name.toLowerCase().contains(query) ||
                    p.root.path.toLowerCase().contains(query),
              )
              .toList();

    // Everything the project rows' menus need, resolved once for the whole
    // list rather than once per row — see [_RowMenuFacts].
    final agentDao = ref.read(agentInstallationDaoProvider);
    final installations = <String, List<AgentInstallation>>{};
    for (final project in projects) {
      installations.putIfAbsent(
        project.root.environmentId,
        () => agentDao.getByEnvironment(project.root.environmentId),
      );
    }
    final menuFacts = (
      workspaces: ref.watch(workspacesControllerProvider),
      counts: ref.watch(workspaceProjectCountsProvider),
      installations: installations,
    );

    // Selected rather than watched whole: this rebuilds the whole tree, and
    // an unrelated settings write — a pane width, a theme — must not.
    final hidingEmptySections = ref.watch(
      settingsControllerProvider.select((s) => s.hideEmptySections),
    );
    final agentFilter = ref.watch(explorerAgentFilterProvider);
    // Watched only under the condition the sections are drawn under: watching it
    // is what pays for the empty filter — see [explorerSectionLayoutProvider].
    final layout = query.isEmpty && projects.isNotEmpty
        ? ref.watch(explorerSectionLayoutProvider)
        : null;

    final syncing = ref.watch(sessionSyncingProvider) > 0;
    // Only whether the mode is on, never the ticked set: this panel builds every
    // row of every expanded project, so watching membership would rebuild it all.
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );

    final Widget body;
    if (projects.isEmpty) {
      body = PanePlaceholder(
        message: allProjects.isEmpty
            ? 'No projects yet.\nUse + to create one from a folder, then its '
                  'CLI sessions are imported automatically.'
            : scoped.isEmpty
            ? 'No projects in this context.\nPick All projects above to see '
                  'everything.'
            : 'No projects match "$_query".',
      );
    } else {
      body = ListView(
        // The same gap the rows put between themselves, above the first and
        // below the last.
        padding: const EdgeInsets.symmetric(vertical: ExplorerRow.gap),
        children: [
          // Spliced into the *same* list rather than wrapped in a column, so the
          // sliver goes on inflating only what is on screen.
          if (query.isEmpty) ...explorerSectionNodes(ref),
          for (final project in projects) ..._projectNodes(project, menuFacts),
        ],
      );
    }

    return PaneScaffold(
      title: 'Explorer',
      // No glyph: the title-bar toggle draws this pane's mark 30px above, in
      // the same column — see [PaneHeader.icon].
      focused: focused,
      actions: [
        _HeaderActions(
          children: [
            if (syncing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: Insets.sm),
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            // One funnel for everything the Explorer holds back: two hiding
            // controls would be two stories about why a session is off screen.
            if (projects.isNotEmpty)
              _ExplorerFilterButton(
                filter: agentFilter,
                hidingEmptySections: hidingEmptySections,
                hiddenSections: layout?.hidden,
                sectionsOnScreen: layout != null,
              ),
            IconButton(
              // A toggle rather than Ctrl-click, which is invisible until
              // somebody tells you about it.
              tooltip: selecting ? 'Leave selection' : 'Select sessions',
              isSelected: selecting,
              icon: Icon(selecting ? AppIcons.x : AppIcons.check),
              onPressed: () =>
                  ref.read(sessionSelectionProvider.notifier).toggleMode(),
            ),
            IconButton(
              tooltip: 'Detect CLI sessions',
              // Not `globe`, which is the Browser surface's glyph; imported
              // cards already use this one for "an agent already wrote this".
              icon: const Icon(AppIcons.clockCounterClockwise),
              onPressed: _showDetected,
            ),
            IconButton(
              // The dialog asks where; nothing has to be selected for it to.
              tooltip: 'New session',
              icon: const Icon(AppIcons.chatCircleDots),
              onPressed: () => NewSessionDialog.show(context),
            ),
            IconButton(
              tooltip: 'New project',
              icon: const Icon(AppIcons.folderPlus),
              onPressed: () => NewProjectDialog.show(context),
            ),
          ],
        ),
      ],
      body: Column(
        children: [
          const WorkspaceScopeBar(),
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
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
                  hintText: 'Search projects',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          if (selecting) const SessionSelectionBar(),
          Expanded(child: body),
        ],
      ),
    );
  }

  // --- rows ------------------------------------------------------------------

  /// The rows for one project: its card, then (when expanded) its tree.
  List<Widget> _projectNodes(Project project, _RowMenuFacts menu) {
    final selectedProjectId = ref.watch(selectedProjectIdProvider);
    final pinned = ref.watch(
      settingsControllerProvider.select((s) => s.isPinned(project.id)),
    );
    final expanded = _expandedProjects.contains(project.id);
    final missing =
        ref.watch(projectPathMissingProvider(project)).asData?.value ?? false;
    // Sessions come from the database; changed files are whatever the
    // per-checkout providers already answered, so no header starts a git wave.
    final summary = ref.watch(projectSummaryProvider(project.id));
    final envDao = ref.watch(executionEnvironmentDaoProvider);
    final env = envDao.getById(project.environmentId);
    final envBadge = env == null ? null : environmentBadge(env);

    final rows = <Widget>[
      ProjectCard(
        name: project.name,
        path: project.root.path,
        expanded: expanded,
        selected: project.id == selectedProjectId,
        missing: missing,
        pinned: pinned,
        environmentBadge: envBadge,
        summary: summary,
        onTap: () => _toggleProject(project),
        // Starts one; the menu below is where the dialog lives.
        onNewSession: () => _startWithDefaults(project),
        onTogglePin: () => _togglePin(project),
        menuItemsBuilder: () => [
          DesktopMenuItem(
            value: 'new-session',
            label: 'New session…',
            icon: AppIcons.chatCircleDots,
          ),
          DesktopMenuItem(
            value: 'terminal',
            label: 'Open terminal',
            icon: AppIcons.terminal,
          ),
          ..._agentMenuItems(menu.installations[project.root.environmentId]),
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
          ..._contextMenuItems(project, menu),
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'pin',
            label: pinned ? 'Unpin' : 'Pin to top',
            icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
          ),
          DesktopMenuItem(
            value: 'refresh',
            // The reading's age, built when the menu opens, so it is the age
            // now and not the age when the row was drawn.
            label: 'Refresh CLI sessions${_checkedSuffix(project.id)}',
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
          if (action.startsWith(_contextAction)) {
            _applyContextAction(project, action);
            return;
          }
          switch (action) {
            case 'new-session':
              _newSessionDialog(project);
            case 'terminal':
              _openTerminal(project);
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
    final visible = ref.watch(visibleProjectSessionsProvider(project.id));
    final sessions = visible.sessions;
    if (sessions.isEmpty) {
      rows.add(
        _TreeHint(
          depth: 1,
          // Never "no sessions yet" over sessions the filter took away: that
          // invites the user to start work they already have.
          message: visible.hidden == 0
              // Before the first-frame import lands nobody has read the CLI
              // stores, so "no sessions yet" would be a claim about nothing.
              ? ref.watch(cliSessionsCheckedProvider).forProject(project.id) ==
                        null
                    ? 'No sessions yet — the CLI stores have not been checked.'
                    : 'No sessions yet — start one with the + on this project.'
              : '${_sessionCount(visible.hidden)} hidden by the agent filter.',
        ),
      );
      return rows;
    }
    rows.addAll(_sessionCards(project, sessions, depth: 1));
    // Said where the rows are missing, and only while a narrowing is in force:
    // a partly-filtered list looks exactly like a shorter one.
    if (visible.hidden > 0) {
      rows.add(
        _TreeHint(
          depth: 1,
          message: '${visible.hidden} more hidden by the agent filter.',
        ),
      );
    }
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
    // Read once: the `_subPathFor*` helpers used to ask the DAO per row, one
    // query a session on every session switch — `session_switch_cost_test`.
    final repositoryPaths = <String, EnvironmentPath>{
      for (final repository
          in ref.read(repositoryDaoProvider).getByProject(project.id))
        repository.id: repository.path,
    };
    final pinnedIds = ref
        .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
        .toSet();
    // The one reading every session list orders by, read once for the row; the
    // status registry already holds these, so it is a map lookup per session.
    final lastActiveOf = ref.read(sessionLastActiveProvider);
    final forest = buildSessionForest(
      sessions.native,
      isPinned: pinnedIds.contains,
      lastActive: lastActiveOf.call,
    );

    // Pinned first, then most recently active, applied to the *top* of each
    // lineage so a child never floats above the session it came from.
    final entries =
        <({SessionActivityOrder order, bool pinned, List<Widget> rows})>[
          for (final node in forest)
            (
              order: (
                lastActive: lastActiveOf(node.session.id),
                createdAt: node.session.createdAt,
              ),
              pinned: pinnedIds.contains(node.session.id),
              rows: _lineageRows(
                project,
                node,
                depth: depth,
                parent: null,
                repositoryPaths: repositoryPaths,
              ),
            ),
          for (final imported in sessions.imported)
            (
              order: (
                lastActive: lastActiveOf(
                  imported.id,
                  storeModifiedAt: imported.updatedAt,
                ),
                createdAt: imported.createdAt,
              ),
              pinned: pinnedIds.contains(imported.id),
              rows: [
                ImportedSessionRow(
                  session: imported,
                  depth: depth + (imported.isSubagent ? 1 : 0),
                  subPath: _subPathForImported(
                    project,
                    imported,
                    repositoryPaths,
                  ),
                  pinned: pinnedIds.contains(imported.id),
                ),
              ],
            ),
        ]..sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          return compareByLastActive(a.order, b.order);
        });
    return [for (final entry in entries) ...entry.rows];
  }

  List<Widget> _lineageRows(
    Project project,
    SessionNode node, {
    required int depth,
    required Session? parent,
    required Map<String, EnvironmentPath> repositoryPaths,
  }) => [
    NativeSessionRow(
      session: node.session,
      depth: depth,
      subPath: _subPathForNative(project, node.session, repositoryPaths),
      pinned: ref
          .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
          .contains(node.session.id),
      link: node.link,
      parentTitle: parent?.title,
      lineageBroken: node.lineageBroken,
    ),
    for (final child in node.children)
      ..._lineageRows(
        project,
        child,
        depth: depth + 1,
        parent: node.session,
        repositoryPaths: repositoryPaths,
      ),
  ];

  // --- contexts ---------------------------------------------------------------

  /// Which context this project is in, offered as the list it could be in
  /// instead — one click to move, and *No context* never leaves the workspace.
  List<PopupMenuEntry<String>> _contextMenuItems(
    Project project,
    _RowMenuFacts menu,
  ) => [
    const DesktopMenuDivider(),
    for (final workspace in menu.workspaces)
      DesktopMenuDetailItem(
        value: '$_contextAction${workspace.id}',
        label: workspace.name,
        // What the context is for, or how big it is — the line that tells two
        // similarly named contexts apart at the moment of choosing.
        detail: describeWorkspace(
          workspace,
          projectCount: menu.counts[workspace.id] ?? 0,
        ),
        detailMaxLines: 1,
        icon: AppIcons.folder,
        selected: project.workspaceId == workspace.id,
      ),
    if (project.workspaceId != null)
      DesktopMenuItem(
        value: '$_contextAction$_noContext',
        label: 'No context',
        icon: AppIcons.minusCircle,
      ),
    DesktopMenuItem(
      value: '$_contextAction$_newContext',
      label: menu.workspaces.isEmpty
          ? 'Add to a new context…'
          : 'Move to a new context…',
      icon: AppIcons.folderPlus,
    ),
  ];

  /// Files [project] where the menu said, and says what happened.
  Future<void> _applyContextAction(Project project, String action) async {
    final target = action.substring(_contextAction.length);
    final controller = ref.read(workspacesControllerProvider.notifier);
    if (target == _noContext) {
      controller.assign(project.id, null);
      // Named in full, because the menu's other leaving verb deletes the
      // project and this one must not be mistaken for it.
      _say('"${project.name}" is no longer in a context. It is still here.');
      return;
    }
    if (target == _newContext) {
      final created = await NewContextDialog.show(
        context,
        forProjectNamed: project.name,
      );
      if (created == null) return;
      controller.assign(project.id, created.id);
      _say('Moved "${project.name}" to ${created.name}.');
      return;
    }
    if (project.workspaceId == target) return;
    controller.assign(project.id, target);
    final name = ref
        .read(workspacesControllerProvider)
        .where((w) => w.id == target)
        .map((w) => w.name)
        .firstOrNull;
    if (name != null) _say('Moved "${project.name}" to $name.');
  }

  // --- shared menu fragments --------------------------------------------------

  /// `New session with <agent>`, offered only when there is a choice: with one
  /// installation the `+` already uses it.
  List<PopupMenuEntry<String>> _agentMenuItems(
    List<AgentInstallation>? installations,
  ) {
    if (installations == null || installations.length < 2) return const [];
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

  /// "Open in File Explorer" is offered only where the host can reach [path] —
  /// an SSH-owned row has no local spelling and the entry would always fail.
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

  /// [repositoryPaths] is this project's repositories, already read. A row
  /// whose repository is absent belongs to another project and has no sub-path.
  String? _subPathForNative(
    Project project,
    Session session,
    Map<String, EnvironmentPath> repositoryPaths,
  ) {
    final directory = session.worktree ?? repositoryPaths[session.repositoryId];
    return directory == null ? null : relativeSubPath(project.root, directory);
  }

  String? _subPathForImported(
    Project project,
    ImportedSession session,
    Map<String, EnvironmentPath> repositoryPaths,
  ) {
    final path = repositoryPaths[session.repositoryId];
    return path == null ? null : relativeSubPath(project.root, path);
  }
}

/// The pane header's action row, clamped to 30px slots: Material's 48px
/// IconButton squares overflow the Explorer's 200px minimum width.
class _HeaderActions extends StatelessWidget {
  const _HeaderActions({required this.children});

  final List<Widget> children;

  static const _slot = Size(30, Chrome.tabStrip);

  @override
  Widget build(BuildContext context) => IconButtonTheme(
    data: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: _slot,
        maximumSize: _slot,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: children),
  );
}

String _sessionCount(int n) => '$n session${n == 1 ? '' : 's'}';

/// Everything the Explorer is hiding, behind one glyph. The icon fills only
/// while the agent filter narrows — hiding empty sections is on by default.
class _ExplorerFilterButton extends ConsumerWidget {
  const _ExplorerFilterButton({
    required this.filter,
    required this.hidingEmptySections,
    required this.hiddenSections,
    required this.sectionsOnScreen,
  });

  final AgentFilter filter;
  final bool hidingEmptySections;

  /// How many sections the empty filter folded away, null when sections are
  /// not on screen at all (a search is narrowing the tree).
  final int? hiddenSections;

  final bool sectionsOnScreen;

  static const String _allAgents = 'agents:all';
  static const String _emptySections = 'sections:empty';
  static const String _agentPrefix = 'agent:';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(agentRegistryProvider);
    final hidden = hiddenSections ?? 0;
    return PopupMenuButton<String>(
      tooltip: _tooltip(registry),
      padding: EdgeInsets.zero,
      iconSize: Chrome.icon,
      icon: Icon(filter.isUnfiltered ? AppIcons.funnel : AppIcons.funnelFill),
      onSelected: (value) {
        final settings = ref.read(settingsControllerProvider.notifier);
        if (value == _emptySections) {
          settings.setHideEmptySections(!hidingEmptySections);
        } else if (value == _allAgents) {
          settings.setExplorerAgentFilter(const {});
        } else {
          settings.setExplorerAgentFilter(
            filter.toggled(value.substring(_agentPrefix.length)).agentIds,
          );
        }
      },
      itemBuilder: (context) => [
        DesktopMenuItem(
          value: _allAgents,
          label: 'All agents',
          icon: AppIcons.listChecks,
          selected: filter.isUnfiltered,
        ),
        for (final id in filterableAgentIds(registry))
          DesktopMenuItem(
            value: '$_agentPrefix$id',
            label: registry.displayNameFor(id),
            icon: AppIcons.robot,
            selected: filter.agentIds.contains(id),
          ),
        // Offered only where it can act: with a search narrowing the tree the
        // sections are not drawn.
        if (sectionsOnScreen) ...[
          const PopupMenuDivider(),
          DesktopMenuItem(
            value: _emptySections,
            // A section folded away for holding nothing is invisible, so this
            // row is the only place a user learns it exists.
            label: !hidingEmptySections
                ? 'Hide empty sections'
                : hidden == 0
                ? 'Showing every section'
                : 'Show $hidden empty section${hidden == 1 ? '' : 's'}',
            icon: AppIcons.funnel,
            selected: hidingEmptySections,
          ),
        ],
      ],
    );
  }

  String _tooltip(AgentRegistry registry) {
    final hidden = hiddenSections ?? 0;
    final agents = agentFilterTooltip(filter, registry);
    if (!hidingEmptySections || hidden == 0) return agents;
    return '$agents \u00b7 $hidden empty '
        'section${hidden == 1 ? '' : 's'} hidden';
  }
}

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
