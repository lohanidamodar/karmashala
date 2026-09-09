part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an
// extension — even one splitting that subclass's own body inside its own
// library, which is all any part of this file is.
// ignore_for_file: invalid_use_of_protected_member

/// What a tab and a pane are **called**, and how strong a tab's liveness is.
///
/// One place, because the tab strip, the overflow picker, the region headers
/// and the status bar all have to agree by construction. The precedence order
/// is stated once, on `_titleForPane`; the OSC intake that feeds it is here
/// too, since a title dropped on the way in is the cheapest way to keep a
/// launcher's own image path off a tab.
extension TerminalPaneTitles on TerminalSessionsController {
  /// The label shown on tab [tabId]: the focused pane's title while the tab is
  /// one pane, and the tab's own directory once it holds more than one.
  ///
  /// Derived here rather than at each call site so the tab strip, the overflow
  /// picker and anything else that names a tab agree by construction.
  String titleForTab(String tabId) {
    final tab = _tabById(tabId);
    if (tab == null) return 'Terminal';
    final visible =
        tab.layout.visiblePanes.where((p) => !_isEmptyRegion(p)).toList();
    if (visible.length > 1) {
      // Deduplicated: a split inherits the selected repository's directory, so
      // both panes report the same label and the join printed it twice. Saying
      // a thing once is the whole of what the header work was about.
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

  /// What one pane is called — the label a region's header puts on its tab.
  ///
  /// Goes through the same per-publish cache [titleForTab] uses, because the
  /// answer can cost a database read (an agent pane resolves its session's
  /// current name) and a region header asks for one per pane per build.
  String titleForPane(String paneId) =>
      _titles.putIfAbsent(paneId, () => _titleForPane(paneId));

  /// What one pane is called, in precedence order.
  ///
  /// 1. **An agent pane takes its session's current name.** The reported bug:
  ///    "i opened archlinux terminal tab, then started claude session and then
  ///    renamed the session, the tab doesn't update the title."
  ///    `TerminalInstance.title` is a `final` field captured when the pane was
  ///    created, so a rename could never reach it. Reading the session row at
  ///    display time keeps one source of truth — the session's name is the
  ///    session's, not a copy the terminal took once — and means a rename shows
  ///    immediately, with no reopen and no restart. An agent pane deliberately
  ///    outranks OSC: Claude Code and Codex both name their own window, and
  ///    letting that win would put the rename back out of reach.
  /// 2. **A shell that named its own window wins for a plain pane.** OSC 0/2 is
  ///    the shell saying what it is doing, which beats any guess.
  /// 3. **Otherwise the directory**, shortened — which is what a terminal tab
  ///    is for, and far more use than five tabs all called "PowerShell".
  /// 4. **Otherwise the profile label**, as before.
  String _titleForPane(String paneId) {
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
      final title = ref.read(sessionDaoProvider).getById(id)?.title.trim();
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

  /// The strongest liveness among tab [tabId]'s panes.
  ///
  /// A tab is only "not running" when nothing in it is, so a split with one live
  /// pane and one restored pane still reads as a working terminal.
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

  /// Every executable this pane's process was started *through*, lowercased and
  /// without its directory. Empty when nothing was put in front of it.
  ///
  /// Asked of `ptyLaunchFor` — the same builder that produced the launch — so
  /// the names refused as titles cannot drift from the names actually spawned.
  /// Taken in the Windows reading of the profile on purpose: an image path
  /// arriving as a window title is a ConPTY behaviour, and on a POSIX host
  /// there is no wrapper for a pane to be named after.
  ///
  /// **Every name, not just the first.** A WSL pane is now spawned as
  /// `cmd.exe /c wsl.exe -d <distro> …`, so the image that announces itself is
  /// no longer the executable — and a filter that knew only the first name let
  /// `C:\Windows\System32\wsl.exe` through as a tab label. The arguments are
  /// searched rather than compared, because `throughCommandPrompt` joins the
  /// whole line into one `/c` argument: the `.exe` is a token inside it, not
  /// the end of it.
  Set<String> _launcherNames(TerminalInstance instance) {
    // An agent pane never consults OSC at all — see [_titleForPane].
    if (instance.agentLaunch != null) return const {};
    final profile = terminalProfileFromId(instance.profileId);
    if (profile == null) return const {};
    // SSH panes do not launch through a local executable. Besides having no
    // launcher name to suppress, asking `ptyLaunchFor` for one would try to
    // reinterpret a remote profile as a host process.
    if (profile.shell == TerminalShell.ssh) return const {};
    final launch = ptyLaunchFor(profile);
    return {
      _basename(launch.executable).toLowerCase(),
      for (final argument in launch.arguments)
        for (final match in _executableToken.allMatches(argument))
          _basename(match.group(0)!).toLowerCase(),
    };
  }

  /// A pane named its own window (OSC 0 or 2).
  void _onPaneTitle(String paneId, String title, Set<String> launchers) {
    final trimmed = title.trim();
    final current = _oscTitles[paneId];
    if (trimmed.isEmpty ? current == null : current == trimmed) return;
    // Dropped on the way in rather than filtered on the way out: a title that
    // says nothing leaves the pane called whatever it was called before, and
    // costs no publish at all.
    if (_namesLauncher(trimmed, launchers)) return;
    if (trimmed.isEmpty) {
      _oscTitles.remove(paneId);
    } else {
      _oscTitles[paneId] = trimmed;
    }
    // Only when it actually changed: a TUI that repaints its title every frame
    // must not republish the whole layout every frame.
    _publish();
  }
}
