part of '../quick_open_sources.dart';

// Commands for running ports, the server, restored sessions and splits.

extension _StatusCommandSources on QuickOpenSources {
  /// The Running tab, by either name, and each http port the last reading
  /// found. Nothing is read for this: a port shows once something has looked.
  List<QuickOpenItem> _runningCommands() {
    final reading = ref.read(runningProvider).reading;
    final facts = ref.read(portFactsProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    return [
      _command(
        'Open Running',
        subtitle: 'What Karmashala runs, and the ports it listens on',
        icon: AppIcons.listMagnifyingGlass,
        keywords: const ['running', 'processes', 'ports', 'dev server'],
        opensTab: true,
        onSelect: () => openRunningTab(ref),
      ),
      _command(
        'Show ports',
        subtitle: 'Every port Karmashala\'s processes listen on',
        icon: AppIcons.listMagnifyingGlass,
        keywords: const ['ports', 'localhost', 'listening'],
        opensTab: true,
        onSelect: () => openRunningTab(ref),
      ),
      if (reading != null)
        for (final (:process, :port) in allPorts(reading))
          if (process.role != RunningRole.server &&
              port.host == null &&
              labelPort(
                process: process.name,
                port: port.port,
                command: process.commandLine ?? process.command,
                facts: facts,
              ).isHttp)
            _command(
              'Open localhost:${port.port}',
              subtitle: process.title ?? process.name,
              icon: AppIcons.globe,
              keywords: const ['localhost', 'port', 'dev server', 'browser'],
              onlyWhenSearched: true,
              onSelect: () => openPortInBrowserPane(
                ref,
                'http://localhost:${port.port}',
                messenger: messenger,
              ),
            ),
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
}
