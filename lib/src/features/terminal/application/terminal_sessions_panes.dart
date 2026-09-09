part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an
// extension — even one splitting that subclass's own body inside its own
// library, which is all any part of this file is.
// ignore_for_file: invalid_use_of_protected_member

/// The **life of one pane**: declaring it, creating it, adopting it and the
/// four listeners that come with it, focusing and resizing it, and — at the
/// other end — deciding whether closing it detaches or ends it, then releasing
/// it and taking those listeners back off.
///
/// `_adopt` and `_unlisten` are a matched pair and are the reason this is one
/// family: every listener attached in the first is dropped in the second, so a
/// disposed instance can never call back into the controller.
extension TerminalPaneLifecycle on TerminalSessionsController {
  /// A pane that exists, holds its profile and its directory, and has no
  /// process — the state a restored pane sits in until its tab is opened.
  String _declarePane(TerminalProfile profile, String? workingDirectory) {
    final paneId = _newId();
    _adopt(
      paneId,
      DormantTerminalInstance(
        id: paneId,
        title: profile.label,
        profileId: profile.id,
        workingDirectory: workingDirectory,
        restoredScrollback: '',
        // What makes opening this tab start it, exactly as a restored tab does.
        wasLive: true,
        gridHint: _gridHint,
      ),
    );
    return paneId;
  }

  /// Closes [paneId], collapsing its split. Closes the tab if it was the last
  /// pane in it.
  ///
  /// Like [closeTab], this detaches a running process instead of killing it
  /// unless [detach] is false.
  void closePane(String paneId, {bool detach = true}) {
    final tab = _tabContaining(paneId);
    if (tab == null) return;
    _userClosedSinceRestore = true;

    final layout = tab.layout.close(paneId);
    // Nothing left, or nothing left but empty regions — the same answer either
    // way, and for the same reason: what stays behind has to be something the
    // user can come back to. See [movePaneToNewTab], the other way a tab can be
    // emptied down to its regions.
    if (layout == null || layout.panes.every(_isEmptyRegion)) {
      closeTab(tab.id, detach: detach);
      return;
    }

    if (detach) {
      _detachOrRelease(paneId);
    } else {
      _releasePane(paneId);
    }
    _replaceTab(
      tab.copyWith(layout: layout, focusedPaneId: _refocused(tab, layout)),
    );
    _focusActivePane();
    persistStructure();
  }

  /// Moves [delta] (a fraction of the split's extent) from child `index + 1` to
  /// child [index] of split [splitId] in tab [tabId].
  void resizePane(String tabId, String splitId, int index, double delta) {
    final tab = _tabById(tabId);
    if (tab == null) return;
    _replaceTab(tab.copyWith(layout: tab.layout.resize(splitId, index, delta)));
  }

  /// Focuses [paneId], activating the tab that holds it and bringing it to the
  /// front of its region.
  ///
  /// Selecting a tab in a region header and focusing a pane are the same act:
  /// a pane behind another is not on screen, so there is nowhere for focus to
  /// sit there. Not persisted — the front pane of each region rides along on
  /// the next structural save and on quit, and writing the layout every time
  /// somebody clicks a pane is exactly the per-interaction database work this
  /// controller is careful not to do.
  void focusPane(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null) return;
    // Already here: a press inside the pane you are already typing in must not
    // republish the layout. A pane calls this on *every* pointer down, so
    // without this a click while selecting text rebuilt the whole tab strip.
    if (_activeTabId == tab.id &&
        tab.focusedPaneId == paneId &&
        tab.layout.groupOf(paneId)?.activePaneId == paneId) {
      _focusActivePane();
      return;
    }
    _activeTabId = tab.id;
    _replaceTab(
      tab.copyWith(layout: tab.layout.activate(paneId), focusedPaneId: paneId),
    );
    _focusActivePane();
  }

  /// Moves focus to the pane adjacent to the focused one in [direction], and
  /// at the edge of the tab's own split to the **workspace group** next door.
  ///
  /// One chord, two levels, and no ambiguity about which: inside a split tab
  /// the next thing left of this pane is the pane beside it; at the tab's edge
  /// it is the group beside it. That is what the arrow means on screen either
  /// way, so it is what the key does.
  void movePaneFocus(PaneDirection direction) {
    final tab = _activeTab;
    final target = tab?.layout.paneInDirection(tab.focusedPaneId, direction);
    if (target != null) {
      focusPane(target);
      return;
    }
    moveGroupFocus(direction);
  }

  String _createPane(
    TerminalProfile profile, {
    String? workingDirectory,
    String? restoredScrollback,
  }) {
    final paneId = _newId();
    _adopt(
      paneId,
      ref.read(terminalInstanceFactoryProvider)(
        id: paneId,
        profile: profile,
        workingDirectory: workingDirectory,
        restoredScrollback: restoredScrollback,
        shellIntegration: _shellIntegrationEnabled,
      ),
    );
    return paneId;
  }

  /// Takes ownership of [instance] and starts tracking whether it needs saving.
  ///
  /// The PTY coalescer already collapses output to one notification per frame,
  /// so this costs one set insert per frame per pane — and stops a quiet pane
  /// being re-encoded three times a minute for nothing.
  void _adopt(String paneId, TerminalInstance instance) {
    _instances[paneId] = instance;
    _livenessMutated();
    _directoriesMutated();
    // A dormant pane is replayed history with nothing running behind it, so its
    // buffer cannot change and there is nothing to track — and reaching for
    // `terminal` here would build the very buffer the restore is avoiding.
    if (instance is! DormantTerminalInstance) {
      void markDirty() => _markDirty(paneId);
      _dirtyListeners[paneId] = markDirty;
      instance.terminal.addListener(markDirty);
    }
    // Republish when the process exits so the pane (and its tab, and the
    // background-session list) stops presenting itself as live. One rebuild per
    // process death — not per frame — so this costs nothing.
    void onLiveness() {
      _livenessMutated();
      if (instance.liveness.value == PaneLiveness.exited) {
        _announceExit(paneId, instance);
      }
      if (instance.liveness.value == PaneLiveness.exited &&
          _shouldCollapse(paneId, instance)) {
        // Not inline: this runs from inside the notifier's own callback, and
        // closing the pane disposes that notifier. One turn later it is a
        // plain call — and the decision is re-asked there, because by then the
        // pane may not be in a tab at all: two panes exiting in the same task
        // queue two collapses, and the first one's close can take the tab (and
        // so the second pane) with it. Re-asking covers that, and the published
        // liveness change is what repaints when the answer has become no.
        Future.microtask(() {
          if (!_shouldCollapse(paneId, instance)) {
            _publish();
            return;
          }
          closePane(paneId, detach: false);
        });
        return;
      }
      _publish();
    }

    _livenessListeners[paneId] = onLiveness;
    instance.liveness.addListener(onLiveness);
    // Republish when the shell says it changed directory, so the tab label and
    // the region header follow a `cd`. One rebuild per `cd` — the instance's
    // notifier drops a report of the directory it already holds, which is what
    // keeps a shell that emits OSC 7 on every prompt redraw free.
    void onDirectory() {
      _directoriesMutated();
      _publish();
    }

    _directoryListeners[paneId] = onDirectory;
    instance.directory.addListener(onDirectory);
    // Nothing else claims `onTitleChange`, so the controller owns it: the tab
    // label is the controller's to derive, and the pane has no idea it is one.
    //
    // Not for a dormant pane: no process ever ran there, so it cannot name its
    // own window — and `terminal` is the `late final` whose first read parses
    // the stored scrollback, which is the cost restore exists to avoid.
    if (instance is! DormantTerminalInstance) {
      // Resolved once per pane and captured, not per title: a TUI that repaints
      // its title every frame must not rebuild a launch every frame.
      final launchers = _launcherNames(instance);
      instance.terminal.onTitleChange = (title) =>
          _onPaneTitle(paneId, title, launchers);
    }
  }

  /// Says out loud that this pane's process stopped **by itself**.
  ///
  /// The one seam out of this feature, and it publishes a fact rather than a
  /// conclusion: nothing here knows who reads [paneExitProvider] or what they
  /// do with it. See [PaneExit].
  ///
  /// Reached only from a pane's own liveness change, which is what makes it the
  /// narrow signal it is: closing a pane, ending a session and quitting the app
  /// each dispose the instance, and [_unlisten] runs first in all three — so
  /// the `exited` a disposal writes for anyone still attached is announced to
  /// nobody. None of those three is an agent finishing its work, and a notice
  /// for them would fire every time somebody closes a terminal.
  void _announceExit(String paneId, TerminalInstance instance) {
    ref
        .read(paneExitProvider.notifier)
        .record(
          PaneExit(
            paneId: paneId,
            sessionId: instance.agentLaunch?.sessionId,
            exitCode: instance.exitCode,
          ),
        );
  }

  /// Whether the pane that just exited should take itself off the screen.
  ///
  /// See [shouldCollapseOnExit] for the rule. All that is left here is the one
  /// thing the pure rule cannot know: whether this pane is still in a tab at
  /// all. It may not be — the decision is re-asked a microtask later, by which
  /// time another pane's collapse may already have taken the tab.
  bool _shouldCollapse(String paneId, TerminalInstance instance) {
    if (_tabContaining(paneId) == null) return false;
    return shouldCollapseOnExit(
      isAgentSession: instance.agentLaunch != null,
      exitCode: instance.exitCode,
    );
  }

  /// How many of [tab]'s regions actually hold a terminal.
  int _occupiedPanes(TerminalTab tab) {
    var count = 0;
    for (final paneId in tab.layout.panes) {
      if (!_isEmptyRegion(paneId)) count++;
    }
    return count;
  }

  /// Whether [paneId] shares its tab with another pane that has something in
  /// it — what "in a split" means to the menus that offer to close or move one.
  bool isPaneInSplit(String paneId) {
    final tab = _tabContaining(paneId);
    return tab != null && _occupiedPanes(tab) > 1;
  }

  /// Detaches [paneId] if a process is still running behind it, and releases it
  /// otherwise.
  ///
  /// The asymmetry is the whole policy: keep-alive exists to protect running
  /// work, and a pane whose shell already exited has none to protect. Without
  /// this, every closed tab would leave a dead entry in the background list.
  void _detachOrRelease(String paneId) {
    final instance = _instances[paneId];
    if (instance == null) return;
    if (!_shouldDetach(instance)) {
      _releasePane(paneId);
      return;
    }
    _detached.add(
      DetachedSession(
        paneId: paneId,
        title: instance.title,
        workingDirectory: instance.workingDirectory,
        detachedAt: ref.read(clockProvider).nowUtc(),
      ),
    );
    _detachedMutated();
  }

  /// Whether closing this pane keeps its process alive — [shouldDetachOnClose]
  /// with the pane's own answers to its four questions.
  bool _shouldDetach(TerminalInstance instance) {
    final recorder = instance.commandBlocks;
    final greeting = instance.greetingLines;
    return shouldDetachOnClose(
      isLive: instance.liveness.value.isLive,
      isAgentSession: instance.agentLaunch != null,
      // Null means the shell is not instrumented and has told us nothing.
      // `pending` is the block being typed *or* run; only one that has started
      // is a command actually executing.
      commandRunning: recorder == null
          ? null
          : recorder.tracker.pending?.hasStarted ?? false,
      // One past the threshold the rule will apply, which is all it can
      // distinguish — so a pane at the scrollback cap still closes in a walk of
      // a few lines.
      nonBlankLines: nonBlankLineCount(
        instance.terminal,
        stopAt: (greeting ?? 0) + kIdleShellHistoryLines + 1,
      ),
      greetingLines: greeting,
    );
  }

  /// Disposes the pane [paneId] owns and stops tracking it.
  void _releasePane(String paneId) {
    final instance = _instances.remove(paneId);
    if (instance == null) return;
    _livenessMutated();
    _directoriesMutated();
    _unlisten(paneId, instance);
    // Both halves of the debt. Dropping only the flag left the pane's
    // *unsaved age* behind for the life of the container — one entry per pane
    // closed while dirty, and Diagnostics reporting an ever-growing "oldest
    // unsaved" beside zero dirty panes, which is exactly the "my work is not
    // being written" signal it exists to give.
    _markClean(paneId);
    _encoded.remove(paneId);
    instance.dispose();
  }

  /// Drops the listeners [_adopt] attached, so a disposed instance can never
  /// call back into the controller.
  void _unlisten(String paneId, TerminalInstance instance) {
    if (instance is! DormantTerminalInstance) {
      instance.terminal.onTitleChange = null;
    }
    _oscTitles.remove(paneId);
    final dirty = _dirtyListeners.remove(paneId);
    if (dirty != null) instance.terminal.removeListener(dirty);
    final liveness = _livenessListeners.remove(paneId);
    if (liveness != null) instance.liveness.removeListener(liveness);
    final directory = _directoryListeners.remove(paneId);
    if (directory != null) instance.directory.removeListener(directory);
  }
}
