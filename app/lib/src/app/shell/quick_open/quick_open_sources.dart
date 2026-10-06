import '../../../core/capabilities/capabilities.dart';
import '../../../features/workspaces/data/workspace_data.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../shell_shortcuts.dart' show shellCommandLabel;
import '../../../features/agents/application/agent_installations_controller.dart';
import '../../../features/agents/application/agent_providers.dart';
import 'package:karmashala_conversations/karmashala_conversations.dart';
import '../../../features/cli_detection/presentation/detected_projects_view.dart';
import '../../../features/environments/presentation/environment_health_dialog.dart';
import '../../../features/automations/application/scheduled_resume_providers.dart';
import '../../../features/automations/presentation/resume_on_reset_dialog.dart';
import '../../../features/fanout/presentation/fanout_dialog.dart';
import '../../../features/onboarding/presentation/quick_start_card.dart';
import '../../../features/git/application/changes_providers.dart';
import '../../../features/notes/application/notes_providers.dart';
import '../../../features/notifications/application/notification_providers.dart';
import '../../../features/projects/application/projects_controller.dart';
import '../../../features/projects/presentation/new_project_dialog.dart';
import '../../../features/editor/application/editor_tab_actions.dart';
import '../../../features/git/application/diff_tab_actions.dart';
import '../../../features/explorer/application/checkout_picker.dart';
import '../../../features/explorer/application/explorer_actions.dart';
import '../../../features/explorer/application/worktree_choices.dart';
import '../../../features/explorer/presentation/unresumable_sessions_dialog.dart';
import '../../../features/sessions/application/session_last_active_providers.dart';
import '../../../features/sessions/application/session_providers.dart';
import '../../../features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/launch.dart';
import '../../../features/sessions/presentation/new_session_dialog.dart';
import '../../../features/sessions/presentation/session_destination_picker.dart'
    show SessionDestination;
import '../../../features/environments/application/environment_providers.dart';
import '../../../features/explorer/presentation/explorer_tree_rows.dart'
    show openTerminalOn;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_git/repositories.dart' show Repository;
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import '../../../features/files/application/files_tab_actions.dart';
import '../../../core/logging/diagnostics_providers.dart'
    show serverLogFileProvider;
import '../../../features/server/application/server_commands.dart';
import '../../../features/server/application/server_files.dart';
import '../../../features/server/application/server_overview.dart';
import '../../../features/server/presentation/server_command_actions.dart';
import '../../../features/settings/presentation/settings_catalog.dart'
    show settingsEntries;
import '../../../features/settings/presentation/settings_nav.dart';
import '../../../features/snippets/application/snippet_insertion.dart';
import '../../../features/snippets/application/snippet_providers.dart';
import '../../../features/snippets/domain/command_snippet.dart';
import '../../../features/snippets/presentation/snippet_dialogs.dart';
import '../../../features/terminal/application/terminal_presets.dart';
import '../../../features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import '../../../features/terminal/presentation/empty_pane_region.dart';
import '../../../features/terminal/presentation/pane_group_strip.dart';
import '../../../features/terminal/presentation/terminal_panel.dart';
import '../../../features/todos/application/todos_providers.dart';
import '../../../features/workspaces/application/workspaces_controller.dart';
import '../../../features/workspaces/domain/workspace_scope.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart' show Chrome, WidthClass;
import '../../../features/agents/presentation/agent_logo.dart';
import '../context_sheet.dart';
import '../karmashala_about_dialog.dart';
import '../phone_routes.dart';
import '../shell_area.dart';
import '../shell_state.dart';
import '../side_panel.dart';
import '../side_panel_state.dart';
import '../tab_picker.dart';
import '../workbench.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'quick_open_step.dart';
import 'repo_file_index.dart';
import 'typed_command_runner.dart' show commandDefaultCheckout;

/// Per-group priors, added to every match in that group. Small on purpose: a
/// large one would let a weak session match outrank an exact command match.
const _sessionWeight = 24.0;
const _workspaceWeight = 14.0;

/// Just under a project: a context is *how the projects are listed*, so on an
/// empty palette it should be visible without displacing the things you open.
const _contextWeight = 12.0;
const _githubWeight = 10.0;
const _branchWeight = 8.0;
const _agentWeight = 4.0;
const _commandWeight = 2.0;

/// Settings rows are listed only once something is typed, so these only order
/// them against other matches: over a command or an agent that matches as
/// well — "theme" means the setting before a verb — and under anything that is
/// work. A page over its sections over its options, so the broader place wins
/// a tie.
const _settingsPageWeight = 6.0;
const _settingsWeight = 5.0;
const _settingsEntryWeight = 4.5;

/// The user's own text, so it outranks an app verb — by a hair only.
const _snippetWeight = 3.0;

/// Below every snippet, so `$` lists the library first and the ways to manage
/// it last — in this group, so `$` on an empty library still offers a way in.
const _snippetAdminWeight = 0.5;

/// Just under an open tab: a preset is a tab you are *about* to have, so what
/// exists comes first and what could exist comes next.
const _presetWeight = 16.0;

/// Below a session, above a project: a shell tab is a place you are already
/// working, but it is not a piece of work in its own right.
const _tabWeight = 18.0;

/// Just under a session's own row: a conversation hit and the session it is in
/// are one destination, and the titled row is the thing the user named.
const _conversationWeight = 22.0;

/// How much the best-ranked conversation is worth over the last one shown, so
/// the search's own order survives the palette's re-sort — and the best still
/// sits no higher than the least recent session row.
const _conversationRankSpread = 2.0;

/// Conversations one search puts in the palette.
const int kQuickOpenConversationLimit = 20;

/// How much the most recent session is worth over the oldest.
const _recencySpread = 12.0;

/// Being in the repository the user is already looking at is worth something,
/// but not much: quick open's whole point is reaching what is *not* on screen.
const _selectedRepoBoost = 10.0;

/// Builds everything quick open can find. Every [QuickOpenItem.onSelect]
/// delegates to the code that owns that jump: a second way in, not a second one.
class QuickOpenSources {
  QuickOpenSources({
    required this.ref,
    required this.context,
    required this.dismiss,
    required this.push,
    this.phone,
  });

  final WidgetRef ref;
  final BuildContext context;

  /// Closes the surface before acting, so a dialog opened from here is not
  /// stacked underneath it. An [action] that returns a future — a session's
  /// resume — is still in progress until it completes, which is how an
  /// "open to the side" knows how long to wait for its tab.
  final void Function(FutureOr<void> Function() action) dismiss;

  /// Goes down a level, the palette staying open: a project lists what can be
  /// done with it rather than jumping to it (owner, 2026-10-01).
  final void Function(QuickOpenStep step) push;

  /// The phone shell, when it is the one on screen: what lands in the
  /// workbench or the side panel is then brought up where the phone shows it,
  /// and what has no place on a phone is not listed.
  final PhoneShellRoutes? phone;

  bool get _onPhone => phone != null;

  /// [action], then the phone's session page: a workbench tab is otherwise
  /// opened out of sight.
  VoidCallback _seen(VoidCallback action) {
    final phone = this.phone;
    if (phone == null) return action;
    return () {
      action();
      phone.showWorkbench();
    };
  }

  /// [action], then the Projects area that draws what it picked: the phone's
  /// Projects tab, or the desktop sidebar switched to Projects (and opened if
  /// it was hidden) — a selection made out of sight is no jump at all
  /// (owner, 2026-10-01). Resolved now, since it runs after the palette has
  /// closed.
  VoidCallback _inProjects(VoidCallback action) {
    final phone = this.phone;
    if (phone != null) {
      return () {
        action();
        phone.showProjects();
      };
    }
    if (!shellAreaShown(ref, ShellArea.projects)) return action;
    final area = ref.read(shellAreaProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    final sidebarHidden = !ref
        .read(shellControllerProvider)
        .explorerPaneVisible;
    return () {
      action();
      area.select(ShellArea.projects);
      if (sidebarHidden) shell.toggleExplorerPane();
    };
  }

  /// A side-panel surface on the phone: the session page's context sheet on
  /// [surface]. Resolved now, since it runs after the palette has closed.
  VoidCallback _inContextSheet(SidePanelSurface surface) {
    final phone = this.phone!;
    final sheet = ref.read(contextSheetSurfaceProvider.notifier);
    return () {
      phone.showWorkbench();
      sheet.show(surface);
      showContextSheet(context);
    };
  }

  List<QuickOpenItem> build({
    List<IndexedFile> files = const [],
    Set<String> changedPaths = const {},
  }) => [
    ..._commands(),
    ..._contexts(),
    ..._workspace(),
    ..._sessions(),
    ..._openTabs(),
    ..._files(files, changedPaths),
    ..._repoFacts(),
    ..._agents(),
    ..._settings(),
    ..._snippets(),
    ..._presets(),
  ];

  // --- commands -----------------------------------------------------------

  QuickOpenItem _command(
    String label, {
    required IconData icon,
    required VoidCallback onSelect,
    String? subtitle,
    String? shortcut,
    List<String> keywords = const [],
    bool opensTab = false,
    bool onlyWhenSearched = false,
  }) => QuickOpenItem(
    id: 'command/$label',
    group: QuickOpenGroup.commands,
    title: label,
    subtitle: subtitle,
    detail: shortcut,
    icon: icon,
    keywords: keywords,
    weight: _commandWeight,
    opensTab: opensTab,
    onlyWhenSearched: onlyWhenSearched,
    onSelect: () => dismiss(onSelect),
  );

  /// Lists the selected checkout's worktrees, once git has, as a step in the
  /// switcher's order and with its search.
  Future<void> _pushWorktrees() async {
    final listening = ref.listenManual(worktreeChoicesProvider, (_, _) {});
    try {
      await ref.read(repoWorktreesProvider.future);
      final choices = listening.read();
      if (choices != null) push(worktreesStep(choices));
    } on Object {
      // Not a repository, or git could not say: there is nothing to list.
    } finally {
      listening.close();
    }
  }

  /// [choices] as a step: the open ones, then the merged ones; a pick moves
  /// the one selection and closes the palette.
  QuickOpenStep worktreesStep(WorktreeChoices choices) {
    String idOf(WorktreeChoice choice) => 'worktree/${choice.path.path}';
    QuickOpenItem item(WorktreeChoice choice, QuickOpenGroup group) =>
        QuickOpenItem(
          id: idOf(choice),
          group: group,
          title: choice.label,
          subtitle: [
            choice.folder,
            if (choice.current) 'current',
            if (choice.sessions == 1) '1 session',
            if (choice.sessions > 1) '${choice.sessions} sessions',
          ].join('  ·  '),
          icon: choice.current ? AppIcons.check : AppIcons.gitBranch,
          onSelect: () => dismiss(_worktreePick(choice)),
        );
    final items = [
      for (final c in choices.open) item(c, QuickOpenGroup.worktrees),
      for (final c in choices.merged) item(c, QuickOpenGroup.mergedWorktrees),
    ];
    return QuickOpenStep(
      id: 'worktrees',
      title: 'Worktrees',
      hintText: 'Search worktrees by branch or folder',
      items: () => items,
      filter: (query, items) {
        final byId = {for (final i in items) i.id: i};
        final shown = choices.where(query);
        QuickOpenSection section(
          QuickOpenGroup group,
          List<WorktreeChoice> rows,
        ) => QuickOpenSection(
          group: group,
          results: [
            for (final c in rows)
              QuickOpenResult(
                item: byId[idOf(c)]!,
                score: 0,
                titlePositions: const [],
              ),
          ],
        );
        return [
          if (shown.open.isNotEmpty)
            section(QuickOpenGroup.worktrees, shown.open),
          if (shown.merged.isNotEmpty)
            section(QuickOpenGroup.mergedWorktrees, shown.merged),
        ];
      },
    );
  }

  /// What picking [choice] does, resolved now: it runs after the palette, and
  /// its `ref`, have gone.
  Future<void> Function() _worktreePick(WorktreeChoice choice) {
    final picker = ref.read(checkoutPickerProvider);
    final projectId = ref.read(selectedCheckoutProvider)?.projectId;
    final messenger = ScaffoldMessenger.maybeOf(context);
    return () async {
      final row = choice.repository;
      if (row != null) {
        picker.select(row);
        return;
      }
      if (projectId == null) return;
      try {
        if (await picker.selectWorktree(projectId, choice.path) == null) {
          messenger?.showSnackBar(
            SnackBar(content: Text('A rescan did not record ${choice.label}.')),
          );
        }
      } on Object catch (error) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Could not rescan: $error')),
        );
      }
    };
  }

  /// The session on screen's resume, and the list of all of them — each only
  /// while it has something to act on.
  List<QuickOpenItem> _resumeCommands() {
    final sessionId = ref.read(selectedSessionIdProvider);
    final native =
        sessionId != null &&
        ref.read(sessionsDataProvider).getById(sessionId) != null;
    final waiting = native
        ? ref.read(sessionResumeBadgeProvider(sessionId))
        : null;
    final all = ref.read(liveScheduledResumesProvider).length;
    const keywords = ['usage', 'limit', 'rate limit', 'reset', 'continue'];
    return [
      if (native)
        _command(
          waiting == null
              ? 'Resume when usage resets…'
              : 'Change scheduled resume…',
          subtitle:
              waiting?.label ??
              'This session, at its limit\'s reset or a time you choose',
          icon: AppIcons.clock,
          keywords: keywords,
          onSelect: () => ResumeOnResetDialog.show(context, [sessionId]),
        ),
      if (native && waiting != null)
        _command(
          'Cancel scheduled resume',
          subtitle: waiting.label,
          icon: AppIcons.x,
          keywords: keywords,
          onSelect: () =>
              ref.read(scheduledResumeControllerProvider).cancelFor(sessionId),
        ),
      if (all > 0)
        _command(
          'Scheduled resumes',
          subtitle: all == 1 ? '1 waiting' : '$all waiting',
          icon: AppIcons.clock,
          keywords: keywords,
          opensTab: true,
          onSelect: () =>
              openSettingsTab(ref, anchor: SettingsAnchor.scheduledResumes),
        ),
    ];
  }

  List<QuickOpenItem> _commands() {
    final panel = ref.read(sidePanelProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    return [
      _command(
        'New project…',
        icon: AppIcons.folderPlus,
        shortcut: shellCommandLabel('project.new'),
        onSelect: () => NewProjectDialog.show(context),
      ),
      // Ungated: the dialog picks its own project and checkout, and with no
      // projects at all it says so rather than being silently absent.
      _command(
        'New session…',
        icon: AppIcons.chatCircleDots,
        shortcut: shellCommandLabel('session.new'),
        onSelect: () => NewSessionDialog.show(context),
      ),
      if (ref.read(selectedRepositoryIdProvider) != null)
        // A step, not a dismissal: git is asked only once it is picked.
        QuickOpenItem(
          id: 'command/Switch worktree…',
          group: QuickOpenGroup.commands,
          title: 'Switch worktree…',
          subtitle: 'Point Changes, Repository and Files at another worktree',
          icon: AppIcons.gitBranch,
          keywords: const ['worktree', 'branch', 'checkout'],
          weight: _commandWeight,
          onSelect: _pushWorktrees,
        ),
      if (ref.read(selectedRepositoryIdProvider) != null)
        _command(
          'Fan out prompt…',
          subtitle: 'Run multiple agents in isolated worktrees',
          icon: AppIcons.gitBranch,
          onSelect: () => FanOutDialog.show(context),
        ),
      ..._resumeCommands(),
      // Listed as verbs, not places: "Notes · Context panel" only answers if
      // you already know the name. Each opens its surface on the way.
      if (ref.read(notesEnabledProvider))
        _command(
          'New note…',
          subtitle: 'Keep an idea without acting on it',
          icon: AppIcons.notePencil,
          keywords: const [
            'note',
            'notes',
            'write',
            'idea',
            'remember',
            'save for later',
            'scratchpad',
          ],
          // The note opens in a tab of its own.
          opensTab: true,
          onSelect: _onPhone
              ? _seen(() => writeNewNote(ref))
              : () {
                  panel.show(SidePanelSurface.notes);
                  writeNewNote(ref);
                },
        ),
      _command(
        'New todo',
        subtitle: 'One line, done or not, in your own order',
        icon: AppIcons.listChecks,
        keywords: const [
          'todo',
          'todos',
          'to-do',
          'task',
          'tasks',
          'checklist',
          'remind',
        ],
        onSelect: _onPhone
            ? () {
                ref.read(todoComposerFocusProvider.notifier).request();
                _inContextSheet(SidePanelSurface.todos)();
              }
            : () {
                panel.show(SidePanelSurface.todos);
                ref.read(todoComposerFocusProvider.notifier).request();
              },
      ),
      _command(
        'Terminal view',
        subtitle: 'Show the terminal in the workbench',
        icon: AppIcons.terminal,
        shortcut: shellCommandLabel('view.toggleTerminal'),
        // The focused group: a command that names no tab means the group the
        // keyboard is in.
        onSelect: _seen(
          () => ref
              .read(terminalSessionsControllerProvider.notifier)
              .showTerminalHere(),
        ),
      ),
      // [_openTabs] lists only the tabs that are *nothing but* tabs; this is
      // the other question — "show me my tabs" — and opens the strip's picker.
      // The phone's Terminals tab is that list.
      if (!_onPhone)
        _command(
          'Switch terminal tab…',
          subtitle: 'Every open tab, by name, session or directory',
          icon: AppIcons.listMagnifyingGlass,
          shortcut: shellCommandLabel('terminal.switchTab'),
          keywords: const ['tabs', 'terminal', 'switch', 'window'],
          onSelect: () => TabPicker.show(context, terminalTabEntries),
        ),
      // Shipped without keys (`unboundShellCommands`): quick open is their
      // way in, and a keymap may bind them. Its jumps land in a terminal the
      // phone does not show under the dialog.
      if (!_onPhone &&
          ref.read(terminalSessionsControllerProvider).tabs.isNotEmpty)
        _command(
          'Commands run here…',
          subtitle: 'What this terminal ran, to jump back to or run again',
          icon: AppIcons.clockCounterClockwise,
          shortcut: shellCommandLabel('terminal.commandsRun'),
          keywords: const ['history', 'commands', 'ran', 'terminal'],
          onSelect: () => TerminalActions(ref).showCommands(context),
        ),
      _command(
        'Detect CLI sessions',
        subtitle: 'Scan the Claude Code and Codex stores for sessions',
        icon: AppIcons.listMagnifyingGlass,
        shortcut: shellCommandLabel('workspace.detectCliSessions'),
        keywords: const ['cli', 'import', 'scan', 'claude', 'codex'],
        onSelect: () => DetectedProjectsView.show(context),
      ),
      _command(
        'About Karmashala',
        icon: AppIcons.info,
        shortcut: shellCommandLabel('app.about'),
        keywords: const ['version', 'build', 'about'],
        onSelect: () => KarmashalaAboutDialog.show(context),
      ),
      ..._restoredSessionCommands(),
      // The drag-only layout verbs, without a mouse. Listed only when they
      // have somewhere to act: always offered and usually inert is noise.
      ..._splitCommands(),
      // A phone has neither: its tabs are the sidebar, and the session
      // page's ⋮ opens the context.
      if (!_onPhone) ...[
        _command(
          'Toggle sidebar',
          icon: AppIcons.treeStructure,
          shortcut: shellCommandLabel('view.toggleExplorer'),
          onSelect: shell.toggleExplorerPane,
        ),
        _command(
          'Toggle context panel',
          icon: AppIcons.sidebarSimple,
          shortcut: shellCommandLabel('view.toggleSidePanel'),
          onSelect: panel.toggle,
        ),
      ],
      for (final surface in SidePanelSurface.offered(
        notesEnabled: ref.read(notesEnabledProvider),
        readsServerDisk: ref.read(capabilitiesProvider).readsServerDisk,
        devicesArea: ref.read(capabilitiesProvider).devicesArea,
      ))
        _command(
          surface.label,
          subtitle: 'Context panel',
          icon: SidePanel.iconFor(surface),
          onSelect: _onPhone
              ? _inContextSheet(surface)
              : () => panel.show(surface),
        ),
      // The phone's session page is already only the pane.
      if (!_onPhone)
        _command(
          'Zen',
          subtitle: 'Only the pane — everything else steps aside',
          icon: AppIcons.arrowsOutSimple,
          shortcut: shellCommandLabel('view.toggleFocusMode'),
          onSelect: () => ref.read(terminalMaximizedProvider.notifier).toggle(),
        ),
      _command(
        'Check system health',
        subtitle: Platform.isWindows
            ? 'MCP bridge, WSL interop, Android tooling, disk, environments'
            : 'MCP bridge, Android tooling, disk, environments',
        icon: AppIcons.checkCircle,
        shortcut: shellCommandLabel('system.checkHealth'),
        keywords: const ['mcp', 'bridge', 'wsl', 'interop', 'disk', 'adb'],
        onSelect: () => EnvironmentHealthDialog.show(context),
      ),
      // A card in the desktop's sidebar, which a phone does not have.
      if (!_onPhone)
        _command(
          kQuickStartCommandLabel,
          subtitle:
              'First steps, where things are, the keys, and what this machine '
              'has — in the sidebar',
          icon: AppIcons.rocketLaunch,
          keywords: const [
            'onboarding',
            'getting started',
            'welcome',
            'tour',
            'help',
            'preflight',
            'setup',
          ],
          onSelect: () => showQuickStart(ref),
        ),
      // About the workspace rather than the machine: rows whose agent has no
      // record of the conversation they name.
      _command(
        'Review sessions with no conversation',
        subtitle:
            'Rows an agent cannot resume — remove them, or start a '
            'conversation in them',
        icon: AppIcons.warningCircle,
        keywords: const [
          'unresumable',
          'missing',
          'orphan',
          'empty',
          'cleanup',
          'tidy',
        ],
        onSelect: () => UnresumableSessionsDialog.show(context),
      ),
      _command(
        'Browse files',
        subtitle: 'This machine, a distribution or a host — side by side',
        icon: AppIcons.folderOpen,
        shortcut: shellCommandLabel('files.browse'),
        keywords: const ['files', 'sftp', 'upload', 'download', 'copy'],
        opensTab: true,
        onSelect: _seen(() => openFilesTabHere(ref)),
      ),
      _command(
        'Open Settings',
        icon: AppIcons.gearSix,
        shortcut: shellCommandLabel('settings.open'),
        keywords: const ['preferences', 'options'],
        opensTab: true,
        onSelect: () => openSettingsTab(ref),
      ),
      _command(
        'Open Usage',
        subtitle: 'Each account’s limits over time, and where the tokens went',
        icon: AppIcons.chartBar,
        shortcut: shellCommandLabel('usage.open'),
        keywords: const ['usage', 'quota', 'limits', 'tokens', 'rate limit'],
        opensTab: true,
        onSelect: () => openUsageTab(ref),
      ),
      _command(
        'Open Stores',
        subtitle: 'Each app on the App Store and Google Play',
        icon: AppIcons.package,
        keywords: const [
          'stores',
          'app store',
          'google play',
          'releases',
          'reviews',
          'ratings',
          'downloads',
        ],
        opensTab: true,
        onSelect: () => openStoresTab(ref),
      ),
      _command(
        'Open Logs',
        subtitle: 'This app’s live log, and this machine’s server log',
        icon: AppIcons.article,
        shortcut: shellCommandLabel('logs.open'),
        keywords: const ['logs', 'log tail', 'server log', 'diagnostics'],
        opensTab: true,
        onSelect: () => openLogsTab(ref),
      ),
      ..._serverCommands(),
    ];
  }

  /// This machine's server, by the Server page's own actions: Start, Restart
  /// or Stop as its state allows (none while this window uses another
  /// machine's), the page itself and the server's log.
  List<QuickOpenItem> _serverCommands() {
    const keywords = ['server', 'host', 'session host', 'karmashala host'];
    final overview = ref.read(serverOverviewProvider).value;
    final log = ref.read(serverLogFileProvider).value;
    final line = describeServerLine(overview);
    return [
      for (final command in serverCommandsFor(overview))
        _command(
          command.label,
          subtitle: line,
          icon: switch (command) {
            ServerCommand.start => AppIcons.play,
            ServerCommand.restart => AppIcons.arrowClockwise,
            ServerCommand.stop => AppIcons.stop,
          },
          keywords: keywords,
          onlyWhenSearched: true,
          onSelect: () => unawaited(runServerCommand(context, command)),
        ),
      _command(
        'Open Server settings',
        subtitle:
            overview?.controlsRefusal ??
            'Status, restart and stop, log and storage',
        icon: AppIcons.gearSix,
        keywords: keywords,
        onlyWhenSearched: true,
        opensTab: true,
        onSelect: () =>
            openSettingsTab(ref, anchor: SettingsAnchor.serverStatus),
      ),
      if (log != null)
        _command(
          'Open server log',
          subtitle: log.path,
          icon: AppIcons.article,
          keywords: const [...keywords, 'server.log', 'logs'],
          onlyWhenSearched: true,
          onSelect: () => unawaited(_openServerLog(log.path)),
        ),
    ];
  }

  /// As Settings → Server → Log's button does; what it needs is read before
  /// quick open's route is gone.
  Future<void> _openServerLog(String path) async {
    final files = ref.read(serverFilesProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failure = await files.openLog(path);
    if (failure != null) {
      messenger?.showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  /// The keyboard's way to the sessions a restart left dormant; listed only
  /// when there are some, and it opens the dialog rather than resuming outright.
  List<QuickOpenItem> _restoredSessionCommands() {
    final count = ref.read(restoredAgentPanesProvider).length;
    if (count == 0) return const [];
    return [
      _command(
        'Resume restored sessions…',
        subtitle:
            '$count session${count == 1 ? '' : 's'} came back as history with '
            'nothing running',
        icon: AppIcons.playCircle,
        keywords: const [
          'resume',
          'restored',
          'restart',
          'continue',
          'dormant',
          'sessions',
        ],
        onSelect: () => TerminalActions(ref).showRestoredSessions(context),
      ),
    ];
  }

  /// The keyboard's way to every layout verb the chrome can be dragged to do. A
  /// *group* divides the workspace; a *region* divides one tab.
  List<QuickOpenItem> _splitCommands() {
    // A phone shows one group and one pane: nothing to split or move into.
    if (WidthClass.of(MediaQuery.sizeOf(context).width).isCompact) return [];
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final emptyGroup = sessions.emptyWorkspaceGroup();
    final slot = sessions.emptySlotInActiveTab();
    final pane = sessions.paneMovableToNewTab();
    final canSplitPane = sessions.focusedPaneIsSplittable();
    return [
      // Left out one axis at a time: a sliver too narrow to halve is still tall.
      if (sessions.canSplitWorkspace(SplitAxis.horizontal))
        _command(
          'Split the workspace right',
          subtitle: 'A new group beside this one, with a strip and a bar',
          icon: AppIcons.squareSplitHorizontal,
          keywords: const ['split', 'group', 'workspace', 'right', 'column'],
          onSelect: () => sessions.splitWorkspace(SplitAxis.horizontal),
        ),
      if (sessions.canSplitWorkspace(SplitAxis.vertical))
        _command(
          'Split the workspace down',
          subtitle: 'A new group under this one, with a strip and a bar',
          icon: AppIcons.squareSplitVertical,
          keywords: const ['split', 'group', 'workspace', 'down', 'row'],
          onSelect: () => sessions.splitWorkspace(SplitAxis.vertical),
        ),
      if (canSplitPane) ...[
        _command(
          'Split this pane right',
          subtitle: 'A second terminal inside this tab',
          icon: AppIcons.squareSplitHorizontal,
          keywords: const ['split', 'pane', 'region', 'terminal', 'right'],
          onSelect: () => sessions.splitPane(SplitAxis.horizontal),
        ),
        _command(
          'Split this pane down',
          subtitle: 'A second terminal inside this tab',
          icon: AppIcons.squareSplitVertical,
          keywords: const ['split', 'pane', 'region', 'terminal', 'down'],
          onSelect: () => sessions.splitPane(SplitAxis.vertical),
        ),
      ],
      if (emptyGroup != null)
        _command(
          'Move a tab into the empty group…',
          subtitle: 'Fill the group you cleared',
          icon: AppIcons.squareSplitHorizontal,
          keywords: const ['group', 'move', 'tab', 'split', 'drag'],
          onSelect: () => TabPicker.show(
            context,
            (ref) => tabsMovableToGroup(ref, emptyGroup),
          ),
        ),
      if (slot != null)
        _command(
          'Move a pane into the empty region…',
          subtitle: 'Fill the empty half of the tab you are in',
          icon: AppIcons.squareSplitVertical,
          keywords: const ['region', 'move', 'pane', 'split', 'drag'],
          onSelect: () =>
              TabPicker.show(context, (ref) => panesMovableInto(ref, slot)),
        ),
      if (pane != null) ...[
        _command(
          'Move this pane to a new tab',
          subtitle: 'Take the focused pane out of its region',
          icon: AppIcons.terminalWindow,
          keywords: const ['region', 'unsplit', 'pane', 'tab', 'move'],
          onSelect: () => sessions.movePaneToNewTab(pane),
        ),
        if (sessions.regionAnchorsBesides(pane).isNotEmpty)
          _command(
            'Move this pane into another region…',
            subtitle: 'Send the focused pane elsewhere in this tab',
            icon: AppIcons.squareSplitVertical,
            keywords: const ['region', 'pane', 'move', 'drag', 'split'],
            onSelect: () =>
                TabPicker.show(context, (ref) => regionsMovableTo(ref, pane)),
          ),
      ],
    ];
  }

  // --- contexts -----------------------------------------------------------

  /// Switching the project list's context from the palette. "All projects" is
  /// listed first: the way out must not be harder to reach than the way in.
  List<QuickOpenItem> _contexts() {
    final workspaces = ref.read(workspacesControllerProvider);
    if (workspaces.isEmpty) return const [];
    final scope = ref.read(workspaceScopeProvider);
    final counts = ref.read(workspaceProjectCountsProvider);
    final scopes = ref.read(workspaceScopeProvider.notifier);

    QuickOpenItem item({
      required String id,
      required String title,
      required String subtitle,
      required IconData icon,
      required bool current,
      required WorkspaceScope target,
    }) => QuickOpenItem(
      id: 'context/$id',
      group: QuickOpenGroup.contexts,
      title: title,
      subtitle: subtitle,
      // Said rather than implied: the palette is the one place you can pick the
      // filter you are already looking at, and doing so must not look broken.
      detail: current ? 'Showing' : null,
      icon: icon,
      keywords: const ['context', 'filter'],
      weight: _contextWeight,
      onSelect: () => dismiss(_inProjects(() => scopes.select(target))),
    );

    return [
      item(
        id: 'all',
        title: 'All projects',
        subtitle: 'Show every project, in any context',
        icon: AppIcons.folders,
        current: scope.isAll,
        target: WorkspaceScope.all,
      ),
      for (final workspace in workspaces)
        item(
          id: workspace.id,
          title: workspace.name,
          subtitle: describeWorkspace(
            workspace,
            projectCount: counts[workspace.id] ?? 0,
          ),
          icon: AppIcons.stack,
          current: scope.workspaceId == workspace.id,
          target: WorkspaceScope.of(workspace.id),
        ),
      item(
        id: 'none',
        title: 'No context',
        subtitle: 'Only the projects filed under nothing',
        icon: AppIcons.minusCircle,
        current: scope.unassignedOnly,
        target: WorkspaceScope.unassigned,
      ),
    ];
  }

  // --- projects and repositories ------------------------------------------

  List<QuickOpenItem> _workspace() {
    final items = <QuickOpenItem>[];
    final workspace = ref.read(workspaceDataProvider);
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
          onSelect: () => push(projectStep(project)),
        ),
      );
      for (final repository in workspace.repositoriesOf(project.id)) {
        items.add(
          QuickOpenItem(
            id: 'repository/${repository.id}',
            group: QuickOpenGroup.workspace,
            title: repository.name,
            subtitle: '${project.name} · repository',
            icon: AppIcons.gitBranch,
            keywords: [repository.path.path],
            weight: _workspaceWeight,
            // Through the project's step, so the breadcrumb and Backspace are
            // what drilling in from the project gives.
            onSelect: () {
              push(projectStep(project));
              push(repositoryStep(project, repository));
            },
          ),
        );
      }
    }
    return items;
  }

  // --- a project's and a repository's own steps ----------------------------

  /// What can be done with [project]: a new session first, so project → Enter
  /// → Enter starts one; its sessions; a terminal and the files there; its
  /// repositories, each a step; and the sidebar jump picking it used to make.
  QuickOpenStep projectStep(Project project) => QuickOpenStep(
    id: 'project/${project.id}',
    title: project.name,
    hintText: 'Act on ${project.name}, or find one of its sessions',
    items: () {
      final repositories = ref
          .read(workspaceDataProvider)
          .repositoriesOf(project.id);
      final id = 'project/${project.id}';
      return [
        _newSessionIn(
          id,
          subtitle: project.name,
          // Read when picked, not listed: the checkout the Explorer's `+` and
          // the typed `start` would choose.
          destination: () => SessionDestination(
            projectId: project.id,
            checkout: commandDefaultCheckout(
              ProviderScope.containerOf(context, listen: false),
              project.id,
            ),
          ),
        ),
        ..._sessions(projectId: project.id),
        // The project's folder, or each repository's when there are several:
        // a parent folder of three clones is rarely where the work is.
        if (repositories.length <= 1)
          ?_terminalIn(id, project.root)
        else
          for (final repository in repositories)
            ?_terminalIn(
              'repository/${repository.id}',
              repository.path,
              title: 'Open a terminal in ${repository.name}',
            ),
        _filesIn(id, project.root),
        _showInSidebar(
          id,
          () => ref.read(selectedProjectIdProvider.notifier).select(project.id),
        ),
        // One repository is the project again; drilling into it says nothing.
        if (repositories.length > 1)
          for (final repository in repositories)
            QuickOpenItem(
              id: '$id/repository/${repository.id}',
              group: QuickOpenGroup.repositories,
              title: repository.name,
              subtitle: repository.path.path,
              icon: AppIcons.gitBranch,
              keywords: const ['repository'],
              onSelect: () => push(repositoryStep(project, repository)),
            ),
      ];
    },
  );

  /// [projectStep] for one checkout: everything there is scoped to it.
  QuickOpenStep repositoryStep(
    Project project,
    Repository repository,
  ) => QuickOpenStep(
    id: 'repository/${repository.id}',
    title: repository.name,
    hintText: 'Act on ${repository.name}, or find one of its sessions',
    items: () {
      final id = 'repository/${repository.id}';
      return [
        _newSessionIn(
          id,
          subtitle: '${project.name} · ${repository.name}',
          destination: () =>
              SessionDestination(projectId: project.id, checkout: repository),
        ),
        ..._sessions(repositoryId: repository.id),
        ?_terminalIn(id, repository.path),
        _filesIn(id, repository.path),
        _showInSidebar(id, () {
          ref.read(selectedProjectIdProvider.notifier).select(project.id);
          ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
        }),
      ];
    },
  );

  /// The New-session dialog, opened on [destination] rather than on whatever
  /// the app is pointed at; nothing is selected until its Start.
  QuickOpenItem _newSessionIn(
    String id, {
    required String subtitle,
    required SessionDestination Function() destination,
  }) => QuickOpenItem(
    id: '$id/new-session',
    group: QuickOpenGroup.sessions,
    title: 'New session…',
    subtitle: subtitle,
    icon: AppIcons.chatCircleDots,
    keywords: const ['start', 'agent'],
    onSelect: () {
      final where = destination();
      dismiss(() => NewSessionDialog.show(context, destination: where));
    },
  );

  /// A shell on [where]'s machine, started in [where] — the Explorer's own
  /// "open a terminal on" — or nothing when that machine is no longer recorded.
  QuickOpenItem? _terminalIn(
    String id,
    EnvironmentPath where, {
    String title = 'Open a terminal',
  }) {
    final environment = ref
        .read(environmentsDataProvider)
        .getById(where.environmentId);
    if (environment == null) return null;
    return QuickOpenItem(
      id: '$id/terminal',
      group: QuickOpenGroup.actions,
      title: title,
      subtitle: where.path,
      icon: AppIcons.terminal,
      keywords: const ['shell', 'terminal', 'console'],
      opensTab: true,
      onSelect: () => dismiss(
        _seen(
          () => openTerminalOn(ref, environment, workingDirectory: where.path),
        ),
      ),
    );
  }

  /// The file browser, this machine on the left and [where] on the right.
  QuickOpenItem _filesIn(String id, EnvironmentPath where) => QuickOpenItem(
    id: '$id/files',
    group: QuickOpenGroup.actions,
    title: 'Browse files',
    subtitle: where.path,
    icon: AppIcons.folderOpen,
    keywords: const ['files', 'sftp', 'upload', 'download', 'copy'],
    opensTab: true,
    onSelect: () => dismiss(
      _seen(() => openFilesTabOn(ref, where.environmentId, path: where.path)),
    ),
  );

  /// What picking a project or repository did before it opened a step: [select]
  /// it, and bring up the Projects area that draws the selection.
  QuickOpenItem _showInSidebar(String id, VoidCallback select) => QuickOpenItem(
    id: '$id/show',
    group: QuickOpenGroup.actions,
    title: _onPhone ? 'Show in Projects' : 'Show in sidebar',
    subtitle: _onPhone ? 'The Projects tab' : 'The Projects sidebar',
    icon: AppIcons.treeStructure,
    keywords: const ['select', 'reveal', 'explorer', 'projects'],
    onSelect: () => dismiss(_inProjects(select)),
  );

  // --- sessions ------------------------------------------------------------

  /// Native and imported sessions, most recently active first. Only *free*
  /// whereabouts: a transcript stat per session would be a disk sweep. A step
  /// narrows them to one [projectId] or one [repositoryId]; the rows are the
  /// full list's own, so picking one does exactly what it does there.
  List<QuickOpenItem> _sessions({String? projectId, String? repositoryId}) {
    final sessionDao = ref.read(sessionsDataProvider);
    final importedDao = ref.read(importedSessionsProvider);
    final workspace = ref.read(workspaceDataProvider);
    final installations = ref.read(agentInstallationsDataProvider);
    final registry = ref.read(agentRegistryProvider);
    final panes = ref.read(paneSessionsProvider);
    final selectedRepository = ref.read(selectedRepositoryIdProvider);
    final lastActiveOf = ref.read(sessionLastActiveProvider);
    final now = ref.read(clockProvider).nowUtc();

    final entries =
        <({SessionActivityOrder order, QuickOpenItem Function(double) make})>[];

    for (final project in ref.read(sortedProjectsProvider)) {
      if (projectId != null && project.id != projectId) continue;
      for (final repository in workspace.repositoriesOf(project.id)) {
        if (repositoryId != null && repository.id != repositoryId) continue;
        final where = '${project.name} · ${repository.name}';
        final here = repository.id == selectedRepository
            ? _selectedRepoBoost
            : 0.0;

        for (final session in sessionDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(
            installations.getById(session.agentInstallationId)?.agentId ?? '',
          );
          final note = _cheapWhereabouts(session, panes);
          final lastActive = lastActiveOf(session.id);
          entries.add((
            order: (lastActive: lastActive, createdAt: session.createdAt),
            make: (recency) => QuickOpenItem(
              id: 'session/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.title,
              // The age of the newest reading, or nothing when we hold none —
              // never "just now" for a session we cannot speak for (§19).
              subtitle: [
                where,
                agent,
                ?note,
                ?lastActive.label(now),
              ].join(' · '),
              detail: session.isArchived
                  ? 'archived'
                  : _statusWord(session.status),
              icon: AppIcons.chatCircle,
              keywords: [
                agent,
                session.status.name,
                if (session.isArchived) 'archived',
                if (session.useWorktree) 'worktree',
                ?session.worktree?.path,
              ],
              weight: _sessionWeight + here + recency,
              opensTab: true,
              onSelect: () =>
                  dismiss(() => focusSession(session.id, imported: false)),
            ),
          ));
        }

        for (final session in importedDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(session.cli);
          final lastActive = lastActiveOf(
            session.id,
            storeModifiedAt: session.updatedAt,
          );
          entries.add((
            order: (lastActive: lastActive, createdAt: session.createdAt),
            make: (recency) => QuickOpenItem(
              id: 'imported/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.displayTitle,
              subtitle: [
                where,
                agent,
                'imported',
                ?lastActive.label(now),
              ].join(' · '),
              detail: session.isSubagent ? 'subagent' : null,
              icon: AppIcons.clockCounterClockwise,
              keywords: [agent, 'imported', session.preview],
              weight: _sessionWeight + here + recency,
              opensTab: true,
              onSelect: () =>
                  dismiss(() => focusSession(session.id, imported: true)),
            ),
          ));
        }
      }
    }

    // Recency is a rank, not a duration: the newest is worth [_recencySpread]
    // over the stalest whether the gap is an hour or a year.
    entries.sort((a, b) => compareByLastActive(a.order, b.order));
    final last = entries.length - 1;
    return [
      for (var i = 0; i < entries.length; i++)
        entries[i].make(
          last == 0 ? _recencySpread : _recencySpread * (1 - i / last),
        ),
    ];
  }

  String? _cheapWhereabouts(Session session, PaneSessions panes) {
    if (panes.paneOf(session.id, where: (liveness) => liveness.isLive) !=
        null) {
      return 'running here';
    }
    if (session.surface == SessionSurface.external) {
      return 'opened in an external terminal';
    }
    return null;
  }

  /// Selects a session and everything above it, through the one walk that
  /// already exists for a clicked toast and a clicked tray item.
  Future<void> focusSession(String openId, {required bool imported}) async {
    focusWatchedSession(
      ProviderScope.containerOf(context, listen: false),
      openId: openId,
      imported: imported,
    );
    ref.read(shellControllerProvider.notifier).focusPane(ShellPane.detail);
    // Picking the session already selected moves nothing the shell hears.
    phone?.showWorkbench();

    // And actually open it: picking a session by name is a request to be *in*
    // it. `openNative` decides between reattach, resume and select.
    final result = await _open(openId, imported: imported);
    final message = result.message;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Reattach, resume or select — whichever [openId] needs.
  Future<ExplorerResult> _open(String openId, {required bool imported}) {
    final actions = ref.read(explorerActionsProvider);
    if (!imported) return actions.openNative(openId);
    final record = ref.read(importedSessionsProvider).getById(openId);
    return record == null
        ? Future.value(const ExplorerResult(ExplorerOutcome.selected))
        : actions.openImported(record);
  }

  // --- conversations ------------------------------------------------------

  /// One row per conversation something was *said* in, never filtered on the
  /// filesystem, so a row whose worktree is gone still opens.
  List<QuickOpenItem> conversations(
    List<ConversationHit> hits,
    String query, {
    DateTime? now,
  }) {
    if (hits.isEmpty) return const [];
    final sessionDao = ref.read(sessionsDataProvider);
    final importedDao = ref.read(importedSessionsProvider);
    final registry = ref.read(agentRegistryProvider);
    final at = now ?? DateTime.now().toUtc();

    final items = <QuickOpenItem>[];
    final seen = <String>{};
    // One row per thread: a switched one holds several conversations.
    final opened = <String>{};
    for (var rank = 0; rank < hits.length; rank++) {
      final hit = hits[rank];
      if (!seen.add(hit.sessionId)) continue;
      // An earlier agent's part of a switched thread opens its session.
      final native =
          sessionDao.getByExternalSessionId(hit.sessionId) ??
          switch (hit.rowId) {
            final rowId? => sessionDao.getById(rowId),
            null => null,
          };
      final imported = native == null
          ? importedDao.getByExternal(hit.cli, hit.sessionId)
          : null;
      final openId = native?.id ?? imported?.id;
      if (openId == null || !opened.add(openId)) continue;
      final title = native?.title ?? imported!.displayTitle;
      final agent = registry.displayNameFor(hit.cli);
      // A ranked page carries its own count; a raw turn list counts itself.
      final matches = hit.matches > 1
          ? hit.matches
          : hits.where((h) => h.sessionId == hit.sessionId).length;
      items.add(
        QuickOpenItem(
          id: 'conversation/${hit.sessionId}',
          group: QuickOpenGroup.conversations,
          title: title,
          subtitle: hit.excerpt,
          // The age of the reading, not of the conversation: the index is only
          // as current as the trigger that last read that transcript (§19).
          detail: [
            if (native?.isArchived ?? false) 'archived',
            if (matches > 1) '$matches matches',
            agent,
            if (hit.indexedAt != null)
              'indexed ${describeAge(at.difference(hit.indexedAt!))}',
          ].join('  ·  '),
          icon: AppIcons.chatCircleDots,
          // FTS5 has already decided this row matches; carrying the query as a
          // keyword stops the fuzzy scorer dropping an excerpt that lacks it.
          keywords: [query, agent],
          weight:
              _conversationWeight +
              _conversationRankSpread * (1 - rank / hits.length),
          opensTab: true,
          onSelect: () =>
              dismiss(() => focusSession(openId, imported: native == null)),
        ),
      );
    }
    return items;
  }

  // --- open terminal tabs --------------------------------------------------

  /// Saved workbench shapes, under `~`. Opening one may leave panes out when a
  /// profile has gone from this machine, and the message says which.
  List<QuickOpenItem> _presets() {
    final presets = ref.read(terminalPresetsProvider);
    final shell = ref.read(shellControllerProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    return [
      for (final preset in presets.all())
        QuickOpenItem(
          id: 'preset/${preset.id}',
          group: QuickOpenGroup.presets,
          title: preset.name,
          subtitle: _describeShape(preset),
          icon: AppIcons.terminalWindow,
          keywords: const ['preset', 'layout', 'terminal', 'workspace'],
          weight: _presetWeight,
          onSelect: () => dismiss(
            _seen(() {
              final opening = presets.open(preset);
              shell.focusPane(ShellPane.detail);
              final said = presetOpenedMessage(preset, opening);
              if (said != null) {
                messenger?.showSnackBar(SnackBar(content: Text(said)));
              }
            }),
          ),
        ),
    ];
  }

  static String _describeShape(TerminalPreset preset) {
    final tabs = preset.tabs.length == 1
        ? '1 tab'
        : '${preset.tabs.length} tabs';
    final panes = preset.paneCount == 1
        ? '1 pane'
        : '${preset.paneCount} panes';
    return '$tabs · $panes';
  }

  /// The terminal tabs nothing else here can reach: one running a session of
  /// ours is already listed as that session, so it is skipped here.
  List<QuickOpenItem> _openTabs() {
    final terminals = ref.read(terminalSessionsControllerProvider);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    final panes = ref.read(paneSessionsProvider);
    return [
      for (final tab in terminals.tabs)
        if (panes.sessionOf(tab.focusedPaneId) == null)
          QuickOpenItem(
            id: 'tab/${tab.id}',
            group: QuickOpenGroup.tabs,
            title: sessions.titleForTab(tab.id),
            // The directory is what tells two `zsh` tabs apart, here for the
            // same reason it does in the strip's picker.
            subtitle: sessions.instanceFor(tab.focusedPaneId)?.workingDirectory,
            detail: tab.id == terminals.activeTabId ? 'current' : null,
            // Settings, a note or a file wear their own glyph, as in the strip.
            icon: documentIconFor(tab) ?? AppIcons.terminal,
            keywords: const ['terminal', 'tab'],
            weight: _tabWeight,
            opensTab: true,
            onSelect: () => dismiss(
              _seen(() {
                sessions.activateTab(tab.id);
                // The group that holds the tab, which activating it has just
                // focused — not whichever group was in front before.
                sessions.showTerminalForTab(tab.id);
                shell.focusPane(ShellPane.detail);
              }),
            ),
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
        // An editor tab, or a diff tab when it has changes.
        opensTab: true,
        onSelect: () => dismiss(
          _seen(
            () => _openFile(
              file,
              changed: changedPaths.contains(file.relativePath),
            ),
          ),
        ),
      ),
  ];

  /// A file with uncommitted changes opens as its diff; any other opens as
  /// itself. Either way it is a tab, and the panel follows.
  void _openFile(IndexedFile file, {required bool changed}) {
    final panel = ref.read(sidePanelProvider.notifier);
    if (changed &&
        ref.read(diffTabActionsProvider).open(file.relativePath) != null) {
      panel.show(SidePanelSurface.changes);
      return;
    }
    panel.show(SidePanelSurface.files);
    ref.read(editorTabActionsProvider).openAt(file.path);
  }

  // --- branches, pull requests and issues ----------------------------------

  List<QuickOpenItem> _repoFacts() {
    final repositoryId = ref.read(selectedRepositoryIdProvider);
    if (repositoryId == null) return const [];
    final facts = ref
        .read(quickOpenCacheProvider.notifier)
        .factsFor(repositoryId);
    final panel = ref.read(sidePanelProvider.notifier);
    final showRepository = _onPhone
        ? _inContextSheet(SidePanelSurface.repository)
        : () => panel.show(SidePanelSurface.repository);
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
          onSelect: () => dismiss(showRepository),
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
          onSelect: () => dismiss(showRepository),
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
          onSelect: () => dismiss(showRepository),
        ),
    ];
  }

  // --- agents --------------------------------------------------------------

  List<QuickOpenItem> _agents() {
    final registry = ref.read(agentRegistryProvider);
    return [
      for (final installation in ref.read(agentInstallationsControllerProvider))
        // A leftover row of an agent the registry forgot has no name to show.
        if (registry.adapterFor(installation.agentId) != null)
          QuickOpenItem(
            id: 'agent/${installation.id}',
            group: QuickOpenGroup.agents,
            title: registry.displayNameFor(installation.agentId),
            subtitle: installation.executable.path,
            detail: installation.version,
            icon: AppIcons.robot,
            leading: AgentLogo(
              agentId: installation.agentId,
              size: Chrome.icon,
            ),
            keywords: [installation.agentId, installation.environmentId],
            weight: _agentWeight,
            opensTab: true,
            // Lands on the Agents section — the entry is an agent, and a jump
            // to the top of Appearance would be a jump to nowhere.
            onSelect: () => dismiss(
              () => openSettingsTab(ref, section: SettingsSectionId.agents),
            ),
          ),
    ];
  }

  // --- settings ------------------------------------------------------------

  /// Every Settings page, section and option this client shows, read from the
  /// catalogue Settings' own page list and search read, and opened the way
  /// they open them. A row titled like an earlier one on the same page — the
  /// Keyboard page and its Keyboard section, the Skills section and its Skills
  /// option — is folded into the earlier, broader one, its words with it.
  List<QuickOpenItem> _settings() {
    final caps = ref.read(capabilitiesProvider);
    final rows = <String, QuickOpenItem Function(List<String> keywords)>{};
    final words = <String, Set<String>>{};
    void add(
      SettingsSectionId page,
      String id,
      String title,
      double weight,
      Iterable<String> keywords,
      VoidCallback open,
    ) {
      final key = '${page.name}/${title.toLowerCase()}';
      (words[key] ??= {}).addAll(keywords);
      rows.putIfAbsent(
        key,
        () =>
            (keywords) => QuickOpenItem(
              id: 'settings/$id',
              group: QuickOpenGroup.settings,
              title: title,
              subtitle: id.startsWith('page/')
                  ? 'Settings'
                  : 'Settings · ${page.label}',
              icon: page.icon,
              keywords: keywords,
              weight: weight,
              opensTab: true,
              onSelect: () => dismiss(open),
            ),
      );
    }

    for (final page in SettingsSectionId.values) {
      if (!page.shownWith(caps)) continue;
      add(
        page,
        'page/${page.name}',
        page.label,
        _settingsPageWeight,
        page.aliases,
        () => openSettingsTab(ref, section: page),
      );
    }
    for (final anchor in SettingsAnchor.values) {
      if (!anchor.shownWith(caps)) continue;
      add(
        anchor.page,
        'anchor/${anchor.name}',
        anchor.title,
        _settingsWeight,
        anchor.keywords,
        () => openSettingsTab(ref, anchor: anchor),
      );
    }
    for (final entry in settingsEntries) {
      if (!entry.anchor.shownWith(caps)) continue;
      add(
        entry.page,
        'entry/${entry.anchor.name}/${entry.label}',
        entry.label,
        _settingsEntryWeight,
        entry.keywords,
        // As a hit in Settings' own search opens it: its section, scrolled to.
        () => openSettingsTab(ref, anchor: entry.anchor),
      );
    }
    return [
      for (final MapEntry(:key, value: build) in rows.entries)
        build(words[key]!.toList()),
    ];
  }

  // --- command snippets ----------------------------------------------------

  /// The saved commands that fit the terminal the user is in. The pane is
  /// captured at build; filtering is by its shell, and untagged fits anywhere.
  List<QuickOpenItem> _snippets() {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    final state = ref.read(terminalSessionsControllerProvider);
    final target = resolveSnippetTarget(terminals, state);
    final all = ref.read(commandSnippetsProvider);
    final fitting = target == null ? all : target.filter(all);
    return [
      for (final snippet in fitting)
        QuickOpenItem(
          id: 'snippet/${snippet.id}',
          group: QuickOpenGroup.snippets,
          title: snippet.label,
          subtitle: snippet.command,
          // The one thing worth a badge: a snippet that will press Enter has
          // to say so *before* it is picked, not afterwards.
          detail: snippet.submit ? 'runs' : null,
          icon: AppIcons.bookBookmark,
          keywords: [
            snippet.command,
            'snippet',
            ?snippet.shellId,
            if (snippet.submit) 'run',
          ],
          weight: _snippetWeight,
          // Typed into the pane, which the phone then shows.
          onSelect: () => dismiss(
            target == null
                ? () => _insert(snippet, target)
                : _seen(() => _insert(snippet, target)),
          ),
        ),
      // Filtering is right; silence about it is not — a library that fits no
      // pane produced an empty palette, which reads as "my snippet is gone".
      if (fitting.length < all.length)
        QuickOpenItem(
          id: 'snippet/hidden',
          group: QuickOpenGroup.snippets,
          title: switch (all.length - fitting.length) {
            1 => '1 snippet is for another shell',
            final n => '$n snippets are for another shell',
          },
          subtitle: target?.shellId == null
              ? "This pane's shell is unknown, so only untagged snippets are "
                    'offered'
              : 'This pane runs ${target!.shellId}',
          icon: AppIcons.bookBookmark,
          keywords: const ['snippet', 'hidden', 'shell', 'other'],
          weight: _snippetAdminWeight,
          onSelect: () => dismiss(
            () => SnippetLibraryDialog.show(
              context,
              suggestedShellId: target?.shellId,
            ),
          ),
        ),
      QuickOpenItem(
        id: 'snippet/new',
        group: QuickOpenGroup.snippets,
        title: 'New command snippet…',
        subtitle: 'Keep a command so you can pick it instead of retyping it',
        icon: AppIcons.plus,
        keywords: const ['snippet', 'command', 'save', 'add'],
        weight: _snippetAdminWeight,
        onSelect: () => dismiss(() => _newSnippet(target)),
      ),
      QuickOpenItem(
        id: 'snippet/manage',
        group: QuickOpenGroup.snippets,
        title: 'Manage command snippets…',
        subtitle: 'Edit or remove what you have saved',
        icon: AppIcons.bookBookmark,
        keywords: const ['snippet', 'library', 'edit', 'delete'],
        weight: _snippetAdminWeight,
        onSelect: () => dismiss(
          () => SnippetLibraryDialog.show(
            context,
            suggestedShellId: target?.shellId,
          ),
        ),
      ),
    ];
  }

  void _insert(CommandSnippet snippet, SnippetTarget? target) {
    final message = target == null
        ? 'Open a terminal to type a snippet into.'
        : insertSnippet(
            terminals: ref.read(terminalSessionsControllerProvider.notifier),
            state: ref.read(terminalSessionsControllerProvider),
            snippet: snippet,
            paneId: target.paneId,
          ).message;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// The notifier is resolved before the `await`, and has to be: [dismiss] pops
  /// the palette, and Riverpod 3 throws on a `ref.read` from an unmounted element.
  Future<void> _newSnippet(SnippetTarget? target) async {
    final snippets = ref.read(commandSnippetsProvider.notifier);
    final draft = await SnippetEditorDialog.show(
      context,
      suggestedShellId: target?.shellId,
    );
    if (draft == null) return;
    snippets.add(
      label: draft.label,
      command: draft.command,
      shellId: draft.shellId,
      submit: draft.submit,
    );
  }
}

/// A session's status as the palette says it: a plain word, or nothing for
/// the states that claim nothing — "unknown" and "created" read as faults.
String? _statusWord(SessionStatus status) => switch (status) {
  SessionStatus.running => 'running',
  SessionStatus.idle => 'idle',
  SessionStatus.completed => 'done',
  SessionStatus.failed => 'failed',
  SessionStatus.cancelled => 'stopped',
  SessionStatus.created || SessionStatus.unknown => null,
};
