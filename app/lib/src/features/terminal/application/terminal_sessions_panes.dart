part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// The **life of one pane**: declaring, creating, adopting, focusing, resizing,
/// and deciding whether closing it detaches or ends it. `_adopt` and `_unlisten`
/// are a matched pair — every listener the first attaches, the second drops.
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

  /// Closes [paneId], collapsing its split, and the tab if it was the last pane
  /// in it. Like [closeTab], a running process is detached rather than killed
  /// unless [detach] is false.
  void closePane(String paneId, {bool detach = true}) {
    final tab = _tabContaining(paneId);
    if (tab == null) return;
    _userClosedSinceRestore = true;

    final layout = tab.layout.close(paneId);
    // Nothing left, or nothing but empty regions: what stays behind has to be
    // something the user can come back to.
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

  /// Focuses [paneId], activating its tab and bringing it to the front of its
  /// region — selecting in a region header and focusing are the same act. Not
  /// persisted: the front pane rides along on the next structural save.
  void focusPane(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null) return;
    // A pane calls this on *every* pointer down, so without the early return a
    // click while selecting text rebuilt the whole tab strip.
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

  /// Moves focus to the pane next door in [direction], and at the edge of the
  /// tab's own split to the **workspace group** next door — one chord, two
  /// levels, each being what the arrow means on screen there.
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
    String? adoptPaneId,
  }) {
    // A host session is named after the pane that opened it, so reattaching to
    // one means opening a pane under that same id — see `terminalSessionId`.
    final paneId = adoptPaneId ?? _newId();
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
  /// The PTY coalescer already collapses output to one notification per frame,
  /// so this costs one set insert per frame per pane.
  void _adopt(String paneId, TerminalInstance instance) {
    _instances[paneId] = instance;
    _livenessMutated();
    _directoriesMutated();
    // A dormant pane's buffer cannot change, and reaching for `terminal` here
    // would build the very buffer the restore is avoiding.
    if (instance is! DormantTerminalInstance) {
      void markDirty() => _markDirty(paneId);
      _dirtyListeners[paneId] = markDirty;
      instance.terminal.addOutputListener(markDirty);
    }
    // Republish on exit so the pane, its tab and the background-session list
    // stop presenting it as live. One rebuild per death, not per frame.
    void onLiveness() {
      _livenessMutated();
      if (instance.liveness.value == PaneLiveness.exited) {
        _announceExit(paneId, instance);
      }
      if (instance.liveness.value == PaneLiveness.exited &&
          _shouldCollapse(paneId, instance)) {
        // Not inline: closing the pane disposes the notifier this runs inside, and
        // two panes exiting in one task queue two collapses.
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
    // So the tab label and region header follow a `cd`. One rebuild per `cd`:
    // the instance drops a report of the directory it already holds, which is
    // what keeps a shell emitting OSC 7 on every prompt redraw free.
    void onDirectory() {
      _directoriesMutated();
      _publish();
    }

    _directoryListeners[paneId] = onDirectory;
    instance.directory.addListener(onDirectory);
    // Not for a dormant pane: nothing ever ran there, and `terminal` is the
    // `late final` whose first read parses the stored scrollback.
    if (instance is! DormantTerminalInstance) {
      // Captured once per pane, not per title: a TUI repainting its title every
      // frame must not rebuild a launch every frame.
      final launchers = _launcherNames(instance);
      instance.terminal.onTitleChange = (title) =>
          _onPaneTitle(paneId, title, launchers);
    }
  }

  /// Says out loud that this pane's process stopped **by itself**. Only a pane's
  /// own liveness change reaches it — a disposal's `exited` is announced to nobody.
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

  /// Whether the pane that just exited should take itself off the screen —
  /// [shouldCollapseOnExit] plus the one thing the pure rule cannot know:
  /// whether this pane is still in a tab at all.
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

  /// Whether [paneId] shares its tab with another *occupied* pane — what "in a
  /// split" means to the menus that offer to close or move one.
  bool isPaneInSplit(String paneId) {
    final tab = _tabContaining(paneId);
    return tab != null && _occupiedPanes(tab) > 1;
  }

  /// Detaches [paneId] if a process is still running behind it, and releases it
  /// otherwise: keep-alive protects running work, and without the asymmetry
  /// every closed tab would leave a dead entry in the background list.
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
      // Null means the shell is not instrumented. `pending` is the block being
      // typed *or* run; only a started one is a command executing.
      commandRunning: recorder == null
          ? null
          : recorder.tracker.pending?.hasStarted ?? false,
      // One past the threshold the rule applies, so a pane at the scrollback
      // cap still closes in a walk of a few lines.
      nonBlankLines: nonBlankLineCount(
        instance.terminal,
        stopAt: (greeting ?? 0) + kIdleShellHistoryLines + 1,
      ),
      greetingLines: greeting,
    );
  }

  /// Disposes the pane [paneId] owns and stops tracking it.
  void _releasePane(String paneId) {
    final ending = _ending.remove(paneId);
    final instance = _instances.remove(paneId);
    if (instance == null) return;
    _livenessMutated();
    _directoriesMutated();
    _unlisten(paneId, instance);
    // Both halves of the debt: dropping only the flag left the unsaved *age*
    // behind, and Diagnostics reported a growing "oldest unsaved" beside zero
    // dirty panes.
    _markClean(paneId);
    _encoded.remove(paneId);
    // Only while it still runs there: a session that already exited has
    // nothing on the host to end.
    if (ending &&
        instance is HostedTerminalInstance &&
        (instance as HostedTerminalInstance).outlivesApp) {
      _endHostedThenDispose(instance as HostedTerminalInstance, instance);
      return;
    }
    instance.dispose();
  }

  /// Ends [hosted]'s session on its host, **then** drops the link: disposing
  /// first is a disconnect, and the host keeps the session running. Bounded,
  /// like the quit path, so a host that will not answer cannot hold the pane.
  void _endHostedThenDispose(
    HostedTerminalInstance hosted,
    TerminalInstance instance,
  ) {
    unawaited(
      hosted
          .endHostedSession()
          .timeout(const Duration(seconds: 5))
          .catchError((Object error) {
            _log.warning('ending the hosted session failed: $error');
          })
          .whenComplete(instance.dispose),
    );
  }

  /// Drops the listeners [_adopt] attached, so a disposed instance can never
  /// call back into the controller.
  void _unlisten(String paneId, TerminalInstance instance) {
    if (instance is! DormantTerminalInstance) {
      instance.terminal.onTitleChange = null;
    }
    _oscTitles.remove(paneId);
    final dirty = _dirtyListeners.remove(paneId);
    if (dirty != null) instance.terminal.removeOutputListener(dirty);
    final liveness = _livenessListeners.remove(paneId);
    if (liveness != null) instance.liveness.removeListener(liveness);
    final directory = _directoryListeners.remove(paneId);
    if (directory != null) instance.directory.removeListener(directory);
  }
}
