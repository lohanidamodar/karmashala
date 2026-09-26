part of 'terminal_sessions_controller.dart';

/// Writing the layout down: the teardown save, the structural save and the
/// budgeted autosave tick. The shape is written now, synchronously, every time;
/// the scrollback text waits for the autosave — see [persistStructure].
extension TerminalLayoutPersistence on TerminalSessionsController {
  /// The **teardown** save — the last write before the process ends. Refuses to
  /// write an empty layout over a stored one, see [_userClosedSinceRestore].
  void persistLayout() => _persist(refreshScrollback: true);

  /// Writes the layout's **shape** only, reusing each pane's existing encoding:
  /// re-encoding costs ~5 ms per busy pane, and the autosave owes that anyway.
  void persistStructure() {
    if (_heldLayoutSaves > 0) {
      _layoutSaveOwed = true;
      return;
    }
    _persist(refreshScrollback: false);
  }

  /// One layout write for a whole bulk verb. The publish is deliberately not
  /// held: a view must stop rendering an instance the moment it is disposed.
  Future<T> withOneLayoutSave<T>(Future<T> Function() body) async {
    _heldLayoutSaves++;
    try {
      return await body();
    } finally {
      _heldLayoutSaves--;
      if (_heldLayoutSaves == 0 && _layoutSaveOwed) {
        _layoutSaveOwed = false;
        // A container disposed while the body was in flight has already written
        // its final layout; reading a provider off a dead `ref` would throw.
        if (!_disposed) _persist(refreshScrollback: false);
      }
    }
  }

  void _persist({required bool refreshScrollback}) {
    final dao = _dao();
    if (dao == null) return;
    try {
      // Written before the guards below can decline to write a layout: a hint
      // for the next launch is not layout data.
      final grid = _gridHint.grid;
      if (grid != null && grid != _writtenGrid) {
        dao.savePaneGrid(grid);
        _writtenGrid = grid;
      }
      final rows = [
        for (final tab in _tabs) _storedTab(tab, refresh: refreshScrollback),
        for (final session in _detached)
          ?_storedDetached(session, refresh: refreshScrollback),
      ];
      if (rows.isEmpty && !_userClosedSinceRestore) {
        final stored = dao.storedTabCount();
        if (stored > 0) {
          _log.error(
            'Refusing to save an empty terminal layout over $stored stored '
            'tab(s): nothing the user closed accounts for it being empty. The '
            'stored layout is left untouched. This should not happen — if '
            'the terminal really is empty, please report it.',
          );
          return;
        }
      }
      dao.saveLayout(
        rows,
        activeTabId: _activeTabId,
        userClosed: _userClosedSinceRestore,
      );
      // Compared by identity, so a save that changed no group costs no row.
      if (!identical(_workspace, _writtenWorkspace)) {
        dao.saveWorkspace(_workspace);
        _writtenWorkspace = _workspace;
      }
      // A structural save left known text unwritten, so ask for the catch-up
      // cadence: ~1 s of exposure instead of the idle interval's 20 s.
      if (!refreshScrollback && hasDirtyScrollback) _autosave.catchUpSoon();
    } catch (error, stack) {
      _log.warning('Could not persist the terminal layout.', error, stack);
    }
  }

  /// Whether any pane still owes a scrollback write — what puts
  /// [ScrollbackAutosave] on its catch-up cadence rather than its idle one.
  bool get hasDirtyScrollback => _dirty.isNotEmpty;

  /// Forgets a pane's debt in both places at once.
  void _markClean(String paneId) {
    _dirty.remove(paneId);
    _dirtySince.remove(paneId);
  }

  /// `Set.add`'s return value is the clean→dirty transition, so the clock is
  /// read once per dirty spell rather than once per notification.
  void _markDirty(String paneId) {
    if (_dirty.add(paneId)) _dirtySince[paneId] = _uptime.elapsed;
  }

  /// Gives a pane the encoding of the history it starts from, so the next
  /// structural save does not re-encode it — 2.9-5.8 ms on the UI isolate.
  void _seedEncoding(String paneId, String? scrollback) {
    if (scrollback == null) return;
    _encoded[paneId] = scrollback;
    _markDirty(paneId);
  }

  /// What persistence owes and what the last write cost, for Settings →
  /// Diagnostics. Built on demand, not published: a value that moved with every
  /// pane's buffer would rebuild a settings page from the terminal's hot path.
  PersistenceTelemetry get persistenceTelemetry {
    final now = _uptime.elapsed;
    Duration? oldest;
    for (final since in _dirtySince.values) {
      final age = now - since;
      if (oldest == null || age > oldest) oldest = age;
    }
    return PersistenceTelemetry(
      dirtyPanes: _dirty.length,
      livePanes: _instances.length,
      oldestUnsaved: oldest,
      lastWrite: _lastWrite,
    );
  }

  /// Re-encodes changed panes for at most [budget] of main-isolate time, which
  /// is what makes a tick cost the same at one pane and at a hundred.
  List<String> saveDirtyScrollback({
    Duration budget = kScrollbackAutosaveBudget,
  }) {
    final dao = _dao();
    if (dao == null || _dirty.isEmpty) return const [];

    final written = <String>[];
    final spent = Stopwatch()..start();
    try {
      final started = _uptime.elapsed;
      for (final paneId in _dirty.toList()) {
        final instance = _instances[paneId];
        if (instance == null) {
          // A pane that has gone owes nothing; drop it rather than retrying
          // every tick from here to shutdown.
          _markClean(paneId);
          continue;
        }
        dao.saveScrollback(paneId, _scrollbackOf(paneId, instance));
        written.add(paneId);
        if (spent.elapsed >= budget) break;
      }
      // Recorded even when the budget was hit: a write that keeps being cut
      // off is what the diagnostics page exists to show.
      _lastWrite = ScrollbackWrite(
        panes: written.length,
        took: spent.elapsed,
        at: started,
      );
    } catch (error, stack) {
      _log.warning('Could not autosave terminal scrollback.', error, stack);
    }
    return written;
  }

  /// This pane's scrollback, encoded only if its buffer moved. With [refresh]
  /// false a dirty pane keeps its cache and stays dirty ([persistStructure]).
  String _scrollbackOf(
    String paneId,
    TerminalInstance instance, {
    bool refresh = true,
  }) {
    // A parked pane gave its buffer up, and a dormant one never built a
    // buffer: their held text *is* the scrollback, and re-encoding would be
    // slower and wrong.
    final held = _heldScrollbackOf(instance);
    if (held != null) {
      _encoded[paneId] = held;
      _markClean(paneId);
      return held;
    }
    if (!refresh || !_dirty.contains(paneId)) {
      final cached = _encoded[paneId];
      if (cached != null) return cached;
    }
    final encoded = encodeScrollback(instance.terminal);
    _encoded[paneId] = encoded;
    // Per pane rather than in bulk, so a pane that was somehow not persisted
    // keeps its flag — the safe direction to be wrong in.
    _markClean(paneId);
    return encoded;
  }

  /// A tab as a stored row, holding the directory the pane **ended up** in
  /// (OSC 7), so a relative path in its scrollback still resolves.
  StoredTerminalTab _storedTab(TerminalTab tab, {required bool refresh}) {
    return StoredTerminalTab(
      id: tab.id,
      layout: tab.layout,
      focusedPaneId: tab.focusedPaneId,
      panes: [
        for (final paneId in tab.layout.panes)
          if (isDocumentPane(paneId))
            StoredTerminalPane(
              id: paneId,
              tabId: tab.id,
              profileId: kDocumentProfileId,
              title: _titleForPane(paneId),
              workingDirectory: null,
              scrollback: '',
            )
          else if (_instances[paneId] case final instance?)
            StoredTerminalPane(
              id: paneId,
              tabId: tab.id,
              profileId: instance.profileId,
              title: instance.title,
              workingDirectory: instance.workingDirectory,
              scrollback: _scrollbackOf(paneId, instance, refresh: refresh),
              agentLaunch: instance.agentLaunch,
              wasLive: instance.liveness.value.isLive,
            ),
      ],
    );
  }

  /// A detached session as a single-pane, tab-less row. Its id is derived from
  /// the pane so repeated saves overwrite rather than accumulate; null if the
  /// instance has gone since it was detached.
  StoredTerminalTab? _storedDetached(
    DetachedSession session, {
    required bool refresh,
  }) {
    final instance = _instances[session.paneId];
    if (instance == null) return null;
    return StoredTerminalTab(
      id: 'detached:${session.paneId}',
      layout: PaneLayout.single(session.paneId),
      focusedPaneId: session.paneId,
      detached: true,
      panes: [
        StoredTerminalPane(
          id: session.paneId,
          tabId: 'detached:${session.paneId}',
          profileId: instance.profileId,
          title: instance.title,
          workingDirectory: instance.workingDirectory,
          scrollback: _scrollbackOf(session.paneId, instance, refresh: refresh),
          agentLaunch: instance.agentLaunch,
          wasLive: instance.liveness.value.isLive,
        ),
      ],
    );
  }
}

/// The parsed buffer [instance] can hand to its replacement, if it has one.
/// Asked **before** [_heldScrollbackOf]: taking a buffer costs nothing, where
/// text costs a parse and sometimes an encode first.
Terminal? _adoptableBufferOf(TerminalInstance instance) => switch (instance) {
  AdoptableTerminalInstance(:final adoptableBuffer) => adoptableBuffer,
  _ => null,
};

/// The scrollback [instance] is already holding as text, if it is.
String? _heldScrollbackOf(TerminalInstance instance) => switch (instance) {
  DormantTerminalInstance(:final restoredScrollback) => restoredScrollback,
  ParkableTerminalInstance(parkedScrollback: final parked?) => parked,
  _ => null,
};
