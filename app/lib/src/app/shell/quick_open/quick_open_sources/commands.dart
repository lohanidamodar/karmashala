part of '../quick_open_sources.dart';

// Quick open's command rows.

extension _CommandSources on QuickOpenSources {
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
        onSelect: _newSessionDialog,
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
      if (ref.read(hideWorkingSessionsProvider))
        _command(
          'Show working sessions',
          subtitle: 'Put busy sessions back in the lists',
          icon: AppIcons.eye,
          keywords: const ['hide', 'working', 'busy', 'sessions'],
          onSelect: () =>
              ref.read(sessionListPrefsProvider.notifier).setHideWorking(false),
        )
      else
        _command(
          'Hide sessions while they work',
          subtitle: 'Until they finish or need you',
          icon: AppIcons.eyeSlash,
          keywords: const ['hide', 'working', 'busy', 'sessions'],
          onSelect: () =>
              ref.read(sessionListPrefsProvider.notifier).setHideWorking(true),
        ),
      if (ref.read(focusModeProvider))
        _command(
          'Turn off Focus',
          subtitle: 'Put notifications and the session lists back',
          icon: AppIcons.target,
          keywords: const ['focus', 'notify', 'notifications', 'quiet'],
          onSelect: () => ref.read(focusModeProvider.notifier).set(false),
        )
      else
        _command(
          'Turn on Focus',
          subtitle:
              'Notify only when needed, and hide sessions while they work',
          icon: AppIcons.target,
          keywords: const ['focus', 'notify', 'notifications', 'quiet'],
          onSelect: () => ref.read(focusModeProvider.notifier).set(true),
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
        'Open Automations',
        subtitle: 'Agent runs on a schedule, an event or a webhook',
        icon: AppIcons.lightning,
        keywords: const [
          'automations',
          'schedule',
          'cron',
          'webhook',
          'runs',
          'resumes',
        ],
        opensTab: true,
        onSelect: () => openAutomationsTab(ref),
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
      _command(
        'Open Agent dashboard',
        subtitle: 'Every project’s sessions at a glance: what needs you',
        icon: AppIcons.squaresFour,
        shortcut: shellCommandLabel('overview.open'),
        keywords: const [
          'overview',
          'board',
          'agents',
          'dashboard',
          'timeline',
        ],
        opensTab: true,
        onSelect: () => openOverviewTab(ref),
      ),
      _command(
        'Show Agent dashboard keys',
        subtitle: 'The keys that triage the dashboard; ? on the board',
        icon: AppIcons.keyboard,
        keywords: const [
          'shortcuts',
          'keyboard',
          'keys',
          'overview',
          'dashboard',
          'help',
        ],
        onSelect: () => showOverviewKeys(context),
      ),
      ..._runningCommands(),
      ..._serverCommands(),
    ];
  }
}
