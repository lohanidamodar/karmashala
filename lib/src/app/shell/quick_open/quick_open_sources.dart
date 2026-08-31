import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/agents/application/agent_installations_controller.dart';
import '../../../features/agents/application/agent_providers.dart';
import '../../../features/cli_detection/application/cli_detection_providers.dart';
import '../../../features/editor/application/code_editor_providers.dart';
import '../../../features/environments/presentation/environment_health_dialog.dart';
import '../../../features/fanout/presentation/fanout_dialog.dart';
import '../../../features/git/application/changes_providers.dart';
import '../../../features/notes/application/notes_providers.dart';
import '../../../features/notifications/application/notification_providers.dart';
import '../../../features/projects/application/projects_controller.dart';
import '../../../features/projects/presentation/new_project_dialog.dart';
import '../../../features/repositories/application/repository_providers.dart';
import '../../../features/sessions/application/session_providers.dart';
import '../../../features/sessions/domain/session.dart';
import '../../../features/sessions/domain/session_launch.dart';
import '../../../features/sessions/presentation/new_session_dialog.dart';
import '../../../features/settings/application/settings_controller.dart';
import '../../../features/settings/presentation/settings_nav.dart';
import '../../../features/settings/presentation/settings_screen.dart';
import '../../../features/terminal/application/terminal_sessions_controller.dart';
import '../../theme/app_icons.dart';
import '../shell_state.dart';
import '../side_panel.dart';
import '../side_panel_state.dart';
import '../tab_picker.dart';
import '../workbench.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'repo_file_index.dart';

/// Per-group priors, added to every match in that group.
///
/// Small on purpose. These decide what an *empty* query lists first and break
/// near-ties between kinds; they must never let a weakly-matched session
/// outrank an exactly-matched command, which is what a large prior would do.
const _sessionWeight = 24.0;
const _workspaceWeight = 14.0;
const _githubWeight = 10.0;
const _branchWeight = 8.0;
const _agentWeight = 4.0;
const _commandWeight = 2.0;

/// Below a session, above a project: a shell tab is a place you are already
/// working, but it is not a piece of work in its own right.
const _tabWeight = 18.0;

/// How much the most recent session is worth over the oldest.
const _recencySpread = 12.0;

/// Being in the repository the user is already looking at is worth something,
/// but not much: quick open's whole point is reaching what is *not* on screen.
const _selectedRepoBoost = 10.0;

/// Builds everything quick open can find.
///
/// Every [QuickOpenItem.onSelect] delegates to the code that already owns that
/// jump — `focusWatchedSession` for sessions, the side panel controller for
/// surfaces, the dialogs for the actions. Quick open is a second way in, never
/// a second implementation.
class QuickOpenSources {
  QuickOpenSources({
    required this.ref,
    required this.context,
    required this.dismiss,
  });

  final WidgetRef ref;
  final BuildContext context;

  /// Closes the surface before acting, so a dialog opened from here is not
  /// stacked underneath it.
  final void Function(VoidCallback action) dismiss;

  List<QuickOpenItem> build({
    List<IndexedFile> files = const [],
    Set<String> changedPaths = const {},
  }) => [
    ..._commands(),
    ..._workspace(),
    ..._sessions(),
    ..._openTabs(),
    ..._files(files, changedPaths),
    ..._repoFacts(),
    ..._agents(),
  ];

  // --- commands -----------------------------------------------------------

  QuickOpenItem _command(
    String label, {
    required IconData icon,
    required VoidCallback onSelect,
    String? subtitle,
    String? shortcut,
    List<String> keywords = const [],
  }) => QuickOpenItem(
    id: 'command/$label',
    group: QuickOpenGroup.commands,
    title: label,
    subtitle: subtitle,
    detail: shortcut,
    icon: icon,
    keywords: keywords,
    weight: _commandWeight,
    onSelect: () => dismiss(onSelect),
  );

  List<QuickOpenItem> _commands() {
    final panel = ref.read(sidePanelProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    return [
      _command(
        'New project…',
        icon: AppIcons.folderPlus,
        shortcut: 'Ctrl+Shift+N',
        onSelect: () => NewProjectDialog.show(context),
      ),
      if (ref.read(selectedRepositoryIdProvider) != null) ...[
        _command(
          'New session…',
          icon: AppIcons.chatCircleDots,
          shortcut: 'Ctrl+N',
          onSelect: () => NewSessionDialog.show(context),
        ),
        _command(
          'Fan out prompt…',
          subtitle: 'Run multiple agents in isolated worktrees',
          icon: AppIcons.gitBranch,
          onSelect: () => FanOutDialog.show(context),
        ),
      ],
      _command(
        'Terminal view',
        subtitle: 'Show the terminal in the workbench',
        icon: AppIcons.terminal,
        shortcut: 'Ctrl+`',
        onSelect: () => ref.read(terminalVisibleProvider.notifier).set(true),
      ),
      // The tabs listed below are only the ones that are *nothing but* tabs
      // (see [_openTabs]), and finding one that way means knowing its name.
      // This is the other question — "show me my tabs" — and it opens the
      // strip's own picker, which holds every tab including the ones running a
      // session.
      _command(
        'Switch terminal tab…',
        subtitle: 'Every open tab, by name, session or directory',
        icon: AppIcons.listMagnifyingGlass,
        keywords: const ['tabs', 'terminal', 'switch', 'window'],
        onSelect: () => TabPicker.show(context, terminalTabEntries),
      ),
      _command(
        'Toggle Explorer',
        icon: AppIcons.treeStructure,
        shortcut: 'Ctrl+B',
        onSelect: shell.toggleExplorerPane,
      ),
      _command(
        'Toggle side panel',
        icon: AppIcons.sidebarSimple,
        shortcut: 'Ctrl+3',
        onSelect: panel.toggle,
      ),
      for (final surface in SidePanelSurface.offered(
        debugMode: ref.read(settingsControllerProvider).debugMode,
        notesEnabled: ref.read(notesEnabledProvider),
      ))
        _command(
          surface.label,
          subtitle: 'Side panel',
          icon: SidePanel.iconFor(surface),
          onSelect: () => panel.select(surface),
        ),
      _command(
        'Focus mode',
        subtitle: 'Give the workbench the whole window',
        icon: AppIcons.arrowsOutSimple,
        shortcut: r'Ctrl+\',
        onSelect: () => ref.read(terminalMaximizedProvider.notifier).toggle(),
      ),
      _command(
        'Check environment health',
        subtitle: 'Windows, WSL, SSH, Git and coding agents',
        icon: AppIcons.checkCircle,
        onSelect: () => EnvironmentHealthDialog.show(context),
      ),
      _command(
        'Open Settings',
        icon: AppIcons.gearSix,
        keywords: const ['preferences', 'options'],
        onSelect: () => SettingsScreen.show(context),
      ),
    ];
  }

  // --- projects and repositories ------------------------------------------

  List<QuickOpenItem> _workspace() {
    final items = <QuickOpenItem>[];
    final repositoryDao = ref.read(repositoryDaoProvider);
    for (final project in ref.read(sortedProjectsProvider)) {
      items.add(
        QuickOpenItem(
          id: 'project/${project.id}',
          group: QuickOpenGroup.workspace,
          title: project.name,
          subtitle: 'Project',
          icon: AppIcons.folder,
          keywords: [project.root.path],
          weight: _workspaceWeight,
          onSelect: () => dismiss(
            () =>
                ref.read(selectedProjectIdProvider.notifier).select(project.id),
          ),
        ),
      );
      for (final repository in repositoryDao.getByProject(project.id)) {
        items.add(
          QuickOpenItem(
            id: 'repository/${repository.id}',
            group: QuickOpenGroup.workspace,
            title: repository.name,
            subtitle: '${project.name} · repository',
            icon: AppIcons.gitBranch,
            keywords: [repository.path.path],
            weight: _workspaceWeight,
            onSelect: () => dismiss(() {
              ref.read(selectedProjectIdProvider.notifier).select(project.id);
              ref
                  .read(selectedRepositoryIdProvider.notifier)
                  .select(repository.id);
            }),
          ),
        );
      }
    }
    return items;
  }

  // --- sessions ------------------------------------------------------------

  /// Native and imported sessions across every project, newest first.
  ///
  /// The whereabouts shown here are the **free** ones — where the session was
  /// started, and whether a pane of ours is running it right now. The Explorer's
  /// row also shows a "last seen" age, which costs a transcript stat per
  /// session; paying that for every session in the workspace to fill a search
  /// list would be a filesystem sweep on every keystroke.
  List<QuickOpenItem> _sessions() {
    final sessionDao = ref.read(sessionDaoProvider);
    final importedDao = ref.read(importedSessionDaoProvider);
    final repositoryDao = ref.read(repositoryDaoProvider);
    final installations = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    final selectedRepository = ref.read(selectedRepositoryIdProvider);

    final entries = <({DateTime at, QuickOpenItem Function(double) make})>[];

    for (final project in ref.read(sortedProjectsProvider)) {
      for (final repository in repositoryDao.getByProject(project.id)) {
        final where = '${project.name} · ${repository.name}';
        final here = repository.id == selectedRepository
            ? _selectedRepoBoost
            : 0.0;

        for (final session in sessionDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(
            installations.getById(session.agentInstallationId)?.agentId ?? '',
          );
          final note = _cheapWhereabouts(session, terminals);
          entries.add((
            at: session.createdAt,
            make: (recency) => QuickOpenItem(
              id: 'session/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.title,
              subtitle: [where, agent, ?note].join(' · '),
              detail: session.status.name,
              icon: AppIcons.chatCircle,
              keywords: [
                agent,
                session.status.name,
                if (session.useWorktree) 'worktree',
                ?session.worktree?.path,
              ],
              weight: _sessionWeight + here + recency,
              onSelect: () =>
                  dismiss(() => _focusSession(session.id, imported: false)),
            ),
          ));
        }

        for (final session in importedDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(session.cli);
          entries.add((
            at: session.updatedAt ?? session.createdAt,
            make: (recency) => QuickOpenItem(
              id: 'imported/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.displayTitle,
              subtitle: '$where · $agent · imported',
              detail: session.isSubagent ? 'subagent' : null,
              icon: AppIcons.clockCounterClockwise,
              keywords: [agent, 'imported', session.preview],
              weight: _sessionWeight + here + recency,
              onSelect: () =>
                  dismiss(() => _focusSession(session.id, imported: true)),
            ),
          ));
        }
      }
    }

    // Recency is a rank, not a duration: the newest session is worth
    // [_recencySpread] over the oldest whether that gap is an hour or a year.
    entries.sort((a, b) => b.at.compareTo(a.at));
    final last = entries.length - 1;
    return [
      for (var i = 0; i < entries.length; i++)
        entries[i].make(
          last == 0 ? _recencySpread : _recencySpread * (1 - i / last),
        ),
    ];
  }

  String? _cheapWhereabouts(
    Session session,
    TerminalSessionsController terminals,
  ) {
    final paneId = session.paneId;
    if (paneId != null &&
        (terminals.instanceFor(paneId)?.liveness.value.isLive ?? false)) {
      return 'running here';
    }
    if (session.surface == SessionSurface.external) {
      return 'opened in an external terminal';
    }
    return null;
  }

  /// Selects a session and everything above it, through the one walk that
  /// already exists for a clicked toast and a clicked tray item.
  void _focusSession(String openId, {required bool imported}) {
    focusWatchedSession(
      ProviderScope.containerOf(context, listen: false),
      openId: openId,
      imported: imported,
    );
    ref.read(shellControllerProvider.notifier).focusPane(ShellPane.detail);
  }

  // --- open terminal tabs --------------------------------------------------

  /// The terminal tabs nothing else here can reach.
  ///
  /// A tab running one of our sessions is *already* in this list as that
  /// session — picking it reattaches and focuses its pane — so listing it again
  /// would only put one destination in the results twice. What is left is the
  /// tabs that are only tabs: a shell, a build, a dev server. Those had no entry
  /// in quick open at all, which meant the tab strip was the one way to reach
  /// one by name, and a strip is hopeless at a hundred.
  ///
  /// This is why the strip's own picker needed no chord of its own: `Ctrl+K`
  /// was already the way to find things by name, and it now finds these too.
  List<QuickOpenItem> _openTabs() {
    final terminals = ref.read(terminalSessionsControllerProvider);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    final sessionPanes = {
      for (final record in ref.read(sessionDaoProvider).getAll())
        ?record.paneId,
    };
    return [
      for (final tab in terminals.tabs)
        if (!sessionPanes.contains(tab.focusedPaneId))
          QuickOpenItem(
            id: 'tab/${tab.id}',
            group: QuickOpenGroup.tabs,
            title: sessions.titleForTab(tab.id),
            // The directory is what tells two `zsh` tabs apart, here for the
            // same reason it does in the strip's picker.
            subtitle: sessions.instanceFor(tab.focusedPaneId)?.workingDirectory,
            detail: tab.id == terminals.activeTabId ? 'current' : null,
            icon: AppIcons.terminal,
            keywords: const ['terminal', 'tab'],
            weight: _tabWeight,
            onSelect: () => dismiss(() {
              sessions.activateTab(tab.id);
              ref.read(terminalVisibleProvider.notifier).set(true);
              shell.focusPane(ShellPane.detail);
            }),
          ),
    ];
  }

  // --- files ---------------------------------------------------------------

  List<QuickOpenItem> _files(
    List<IndexedFile> files,
    Set<String> changedPaths,
  ) => [
    for (final file in files)
      QuickOpenItem(
        id: 'file/${file.relativePath}',
        group: QuickOpenGroup.files,
        title: file.name,
        subtitle: file.relativePath,
        detail: changedPaths.contains(file.relativePath) ? 'modified' : null,
        icon: AppIcons.article,
        weight: changedPaths.contains(file.relativePath) ? 6 : 0,
        onSelect: () => dismiss(
          () => _openFile(
            file,
            changed: changedPaths.contains(file.relativePath),
          ),
        ),
      ),
  ];

  /// A file with uncommitted changes opens in the diff we already render; any
  /// other opens in the configured editor, which is what tapping it in the
  /// Files surface does. Either way the panel shows where you landed.
  Future<void> _openFile(IndexedFile file, {required bool changed}) async {
    final panel = ref.read(sidePanelProvider.notifier);
    if (changed) {
      ref.read(selectedChangeFileProvider.notifier).select(file.relativePath);
      panel.select(SidePanelSurface.changes);
      return;
    }
    panel.select(SidePanelSurface.files);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(editorActionsProvider).openPath(file.hostPath);
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text(error is StateError ? error.message : '$error')),
      );
    }
  }

  // --- branches, pull requests and issues ----------------------------------

  List<QuickOpenItem> _repoFacts() {
    final repositoryId = ref.read(selectedRepositoryIdProvider);
    if (repositoryId == null) return const [];
    final facts = ref
        .read(quickOpenCacheProvider.notifier)
        .factsFor(repositoryId);
    final panel = ref.read(sidePanelProvider.notifier);
    return [
      for (final branch in facts.branches)
        QuickOpenItem(
          id: 'branch/$branch',
          group: QuickOpenGroup.branches,
          title: branch,
          subtitle: facts.branches.first == branch
              ? 'Checked out here'
              : 'Worktree branch',
          icon: AppIcons.gitBranch,
          weight: _branchWeight,
          onSelect: () => dismiss(() => panel.select(SidePanelSurface.changes)),
        ),
      for (final pr in facts.pullRequests)
        QuickOpenItem(
          id: 'pr/${pr.number}',
          group: QuickOpenGroup.github,
          title: pr.title,
          subtitle:
              'PR #${pr.number}${pr.author == null ? '' : ' · ${pr.author}'}',
          detail: pr.state.toLowerCase(),
          icon: AppIcons.gitMerge,
          keywords: ['#${pr.number}', 'pull request'],
          weight: _githubWeight,
          onSelect: () => dismiss(() => panel.select(SidePanelSurface.github)),
        ),
      for (final issue in facts.issues)
        QuickOpenItem(
          id: 'issue/${issue.number}',
          group: QuickOpenGroup.github,
          title: issue.title,
          subtitle: 'Issue #${issue.number}',
          detail: issue.state.toLowerCase(),
          icon: AppIcons.warningCircle,
          keywords: ['#${issue.number}', 'issue'],
          weight: _githubWeight,
          onSelect: () => dismiss(() => panel.select(SidePanelSurface.github)),
        ),
    ];
  }

  // --- agents --------------------------------------------------------------

  List<QuickOpenItem> _agents() {
    final registry = ref.read(agentRegistryProvider);
    return [
      for (final installation in ref.read(agentInstallationsControllerProvider))
        QuickOpenItem(
          id: 'agent/${installation.id}',
          group: QuickOpenGroup.agents,
          title: registry.displayNameFor(installation.agentId),
          subtitle: installation.executable.path,
          detail: installation.version,
          icon: AppIcons.robot,
          keywords: [installation.agentId, installation.environmentId],
          weight: _agentWeight,
          // Lands on the Agents section — the entry is an agent, and a jump
          // to the top of Appearance would be a jump to nowhere.
          onSelect: () => dismiss(
            () => SettingsScreen.show(
              context,
              section: SettingsSectionId.agents,
            ),
          ),
        ),
    ];
  }
}
