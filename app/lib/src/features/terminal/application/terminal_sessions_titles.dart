part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// What a tab and a pane are **called**, and how strong a tab's liveness is —
/// one place, so the strip, the picker, the region headers and the status line
/// agree by construction. The precedence order is stated on `_titleForPane`.
extension TerminalPaneTitles on TerminalSessionsController {
  /// The label shown on tab [tabId]: the focused pane's title while the tab is
  /// one pane, and the tab's own directory once it holds more than one.
  String titleForTab(String tabId) {
    final tab = _tabById(tabId);
    if (tab == null) return 'Terminal';
    final visible = tab.layout.visiblePanes
        .where((p) => !_isEmptyRegion(p))
        .toList();
    if (visible.length > 1) {
      // Deduplicated: a split inherits the selected repository's directory, so
      // both panes report the same label and the join printed it twice.
      final names = <String>[];
      for (final pane in visible) {
        final name = _titles.putIfAbsent(pane, () => _titleForPane(pane));
        if (!names.contains(name)) names.add(name);
      }
      return names.join(' | ');
    }
    final named = _isEmptyRegion(tab.focusedPaneId)
        ? tab.layout.panes.firstWhere(
            (paneId) => !_isEmptyRegion(paneId),
            orElse: () => tab.focusedPaneId,
          )
        : tab.focusedPaneId;
    return _titles.putIfAbsent(named, () => _titleForPane(named));
  }

  /// What one pane is called. Through the same per-publish cache [titleForTab]
  /// uses: the answer can cost a database read, and a region header asks for
  /// one per pane per build.
  String titleForPane(String paneId) =>
      _titles.putIfAbsent(paneId, () => _titleForPane(paneId));

  /// What one pane is called: an agent pane's session name read live, then OSC
  /// 0/2, then the shortened directory, then the profile label.
  String _titleForPane(String paneId) {
    // A document names itself: no shell named its window and it is in no
    // directory.
    if (isSettingsPane(paneId)) return 'Settings';
    if (isDevicePane(paneId)) return 'Devices';
    // A preview is named for its device; its serial until the list has it.
    if (devicePreviewSerial(paneId) case final serial?) {
      final devices = ref.read(devicesProvider).asData?.value ?? const [];
      for (final device in devices) {
        if (device.serial == serial) return device.displayName;
      }
      return serial;
    }
    if (isUsagePane(paneId)) return 'Usage';
    if (isStoresPane(paneId)) return 'Stores';
    if (isLogsPane(paneId)) return 'Logs';
    if (isFilesPane(paneId)) return 'Files';
    if (isBrowserPane(paneId)) return 'Browser';
    // A document id: a host path, which reads `/` and `\` alike, or a POSIX
    // path on another machine, where `\` is part of a name.
    if (editorPanePath(paneId) case final path?) {
      return documentNameOf(path);
    }
    if (notePaneNoteId(paneId) case final noteId?) {
      for (final note in ref.read(notesProvider)) {
        if (note.id == noteId) return note.displayTitle;
      }
      return 'Note';
    }
    // A chat pane is named for its session, read live like an agent pane's.
    if (chatPaneSessionId(paneId) case final sessionId?) {
      return _sessionTitle(sessionId) ?? 'Session';
    }
    // git prints a relative path with `/` whatever the host separator is.
    if (diffPaneTarget(paneId) case final diff?) {
      return p.posix.basename(diff.path);
    }
    final instance = _instances[paneId];
    if (instance == null) return 'Terminal';

    final sessionId = instance.agentLaunch?.sessionId;
    if (sessionId != null) {
      final title = _sessionTitle(sessionId);
      if (title != null) return title;
    }
    if (instance.agentLaunch != null) return instance.title;

    final osc = _oscTitles[paneId];
    if (osc != null) return osc;

    final directory = instance.workingDirectory;
    if (directory != null && directory.isNotEmpty) {
      return directoryLabel(directory, home: _homeDirectory);
    }
    return instance.title;
  }

  /// The current name of session [id], or null when there is no such session.
  String? _sessionTitle(String id) {
    try {
      final title = ref.read(sessionsDataProvider).getById(id)?.title.trim();
      return (title == null || title.isEmpty) ? null : title;
    } catch (_) {
      // No database in this container — a terminal-only test. The pane keeps
      // the name it launched with.
      return null;
    }
  }

  /// Where `~` points. Read once: it cannot change while the app is running.
  static final String? _homeDirectory =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];

  /// The strongest liveness among tab [tabId]'s panes: a tab is only "not
  /// running" when nothing in it is.
  PaneLiveness livenessForTab(String tabId) {
    final tab = _tabById(tabId);
    if (tab == null) return PaneLiveness.exited;
    var result = PaneLiveness.exited;
    for (final paneId in tab.layout.panes) {
      final liveness = _instances[paneId]?.liveness.value;
      if (liveness == PaneLiveness.live) return PaneLiveness.live;
      if (liveness == PaneLiveness.restored) result = PaneLiveness.restored;
    }
    return result;
  }

  /// Every executable this pane was started *through*, so a title merely
  /// reciting one can be refused — an image path as a window title is ConPTY.
  Set<String> _launcherNames(TerminalInstance instance) {
    // An agent pane never consults OSC at all — see [_titleForPane].
    if (instance.agentLaunch != null) return const {};
    final profile = terminalProfileFromId(instance.profileId);
    if (profile == null) return const {};
    // An SSH pane launches through no local executable, and asking
    // `ptyLaunchFor` would reinterpret a remote profile as a host process.
    if (profile.shell == TerminalShell.ssh) return const {};
    final launch = ptyLaunchFor(profile);
    return launcherNames(launch.executable, launch.arguments);
  }

  /// A pane named its own window (OSC 0 or 2).
  void _onPaneTitle(String paneId, String title, Set<String> launchers) {
    final trimmed = title.trim();
    final current = _oscTitles[paneId];
    if (trimmed.isEmpty ? current == null : current == trimmed) return;
    // Dropped on the way in, so a title that says nothing leaves the pane
    // called what it was and costs no publish at all.
    if (namesLauncher(trimmed, launchers)) return;
    if (trimmed.isEmpty) {
      _oscTitles.remove(paneId);
    } else {
      _oscTitles[paneId] = trimmed;
    }
    // Only when it actually changed: a TUI repainting its title every frame
    // must not republish the whole layout every frame.
    _publish();
  }
}
