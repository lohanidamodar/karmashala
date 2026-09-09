part of 'terminal_sessions_controller.dart';

/// Writing the layout down: the teardown save, the structural save, the
/// budgeted autosave tick, and the dirty set the three of them share.
///
/// The distinction the whole family turns on is stated on [persistStructure]:
/// the *shape* is written now, synchronously, every time, and the scrollback
/// *text* is refreshed on the autosave's next budgeted tick. Reading it back
/// is `terminal_sessions_restore.dart`.
extension TerminalLayoutPersistence on TerminalSessionsController {
  /// Writes the whole layout — tabs, splits, detached sessions and every
  /// pane's scrollback, re-encoding whatever has moved since it was last
  /// written.
  ///
  /// This is the **teardown** save: the controller's own `onDispose`,
  /// [shutdownProcesses], and the quit sequence's explicit snapshot. The
  /// container *is* disposed on quit now (Loop 61's lifecycle owner), but that
  /// happens inside a bounded budget several steps in, and
  /// `windowManager.destroy()` ends the process the moment the sequence returns
  /// — so anything not already written when the user quits is simply gone, and
  /// this is the last chance to write it.
  ///
  /// Structural changes use [persistStructure] instead.
  ///
  /// Does nothing when no database is wired up (tests, and any bootstrap that
  /// has not opened one).
  ///
  /// Also does nothing when it would replace a non-empty stored layout with
  /// an empty one that no user action accounts for — see
  /// [_userClosedSinceRestore]. That case is a bug by construction, and the
  /// difference between a bug and a data loss is whether the bug is allowed to
  /// write.
  void persistLayout() => _persist(refreshScrollback: true);

  /// Writes the layout's **shape** — which tabs exist, in what order, split
  /// how, with which panes — without re-encoding a buffer to get text the
  /// autosave already owes a write for.
  ///
  /// Runs on every structural change (open, split, close, detach, end, start).
  /// The shape is written synchronously and in full, because losing a tab
  /// layout to a crash is far worse than a slow save and a layout is small. The
  /// scrollback *text* is a different question: re-encoding is the expensive
  /// half of a save — the codec walks every line and emits an SGR run per style
  /// change, ~5 ms for a pane holding a full durable window — and on a busy
  /// layout every live pane is dirty, so a structural save was paying for
  /// all of them. At the hundred-pane scale target that is the bulk of the
  /// 645 ms `tool/benchmark/terminal_scale_bench.dart` measured, and it is what
  /// the owner sees as "resuming session still makes ui laggy".
  ///
  /// So a structural save writes the encoding each pane *already* has and
  /// leaves the pane dirty. [saveDirtyScrollback] then refreshes it on the next
  /// tick, inside the 8 ms budget that exists for exactly this, and
  /// [persistLayout] flushes the rest on the way out. A pane the store has
  /// never seen has no encoding to reuse, so it is encoded here and its text is
  /// never merely assumed.
  ///
  /// The exposure this buys is bounded, and smaller than the one the app
  /// already accepts. `kScrollbackAutosaveInterval` documents the worst case as
  /// 20 s of output lost to a close-to-tray kill; a save that leaves text
  /// behind here asks the autosave for its catch-up cadence
  /// ([ScrollbackAutosave.catchUpSoon]), so the text lands about a second
  /// later. And nothing here can lose a *tab*: the shape is written now,
  /// synchronously, every time.
  void persistStructure() {
    if (_heldLayoutSaves > 0) {
      _layoutSaveOwed = true;
      return;
    }
    _persist(refreshScrollback: false);
  }

  /// Holds the structural save until [body] finishes, then writes it once.
  ///
  /// The shape [closeTabs] has, for a bulk verb whose steps belong to somebody
  /// else. Resuming four restored sessions is four passes through
  /// [startAgentInPane], and each of those ends in a full [persistStructure] —
  /// the whole layout, every tab, synchronously — so one thing the user asked
  /// for once would be four layout writes and four fsyncs. This makes it one,
  /// whatever the count, exactly as closing twenty tabs is one.
  ///
  /// **The publish is deliberately *not* held.** Starting a pane releases its
  /// instance and adopts a new one, and it is the publish that tells the pane's
  /// view to stop rendering the object that has just been disposed — see
  /// [terminalPaneInstanceProvider] for what that looked like the last time it
  /// did not happen. Inside one synchronous call the gap does not exist; across
  /// the frame a bulk resume yields between panes it does, and a mounted view
  /// holding a disposed `FocusNode` would be a crash rather than a saving. So
  /// each pane publishes as it comes up — which is also what lets the user
  /// watch them arrive — and the expensive half, the layout write, is the half
  /// that happens once.
  ///
  /// [persistLayout] is not held: it is the teardown save, and a quit inside a
  /// bulk verb must still write everything on the way out.
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
      // Independent of the layout, and written before the guards below can
      // decline to write one: a hint for the next launch is not layout data
      // and losing it to a refused save would be a silent regression.
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
      // How those tabs were divided into groups. Written after them, and only
      // when it moved: the tree is compared by identity, so a save that changed
      // no group costs no row.
      if (!identical(_workspace, _writtenWorkspace)) {
        dao.saveWorkspace(_workspace);
        _writtenWorkspace = _workspace;
      }
      // A structural save that reused an encoding has left text unwritten that
      // this controller already knows about, so the autosave is asked for its
      // catch-up cadence rather than whatever idle tick happens to be armed.
      // That makes the exposure ~1 s instead of the 20 s the idle interval
      // bounds it at — better than the window a full re-encode was closing,
      // rather than merely no worse.
      if (!refreshScrollback && hasDirtyScrollback) _autosave.catchUpSoon();
    } catch (error, stack) {
      _log.warning('Could not persist the terminal layout.', error, stack);
    }
  }

  /// Whether any pane still owes a scrollback write.
  ///
  /// What tells [ScrollbackAutosave] to come back on its catch-up cadence
  /// rather than its idle one.
  bool get hasDirtyScrollback => _dirty.isNotEmpty;

  /// Forgets a pane's debt in both places at once.
  void _markClean(String paneId) {
    _dirty.remove(paneId);
    _dirtySince.remove(paneId);
  }

  /// Records that a pane's buffer has moved past what [_encoded] holds.
  ///
  /// `Set.add`'s return value is the clean→dirty transition, so the clock is
  /// read once per dirty spell rather than once per notification — see
  /// [_dirtySince].
  void _markDirty(String paneId) {
    if (_dirty.add(paneId)) _dirtySince[paneId] = _uptime.elapsed;
  }

  /// Gives a pane the encoding of the history it starts from, and records that
  /// it owes a fresh one.
  ///
  /// The pane a start or a restore has just built holds text the store already
  /// has — the buffer it adopted, or the scrollback it replayed — plus a
  /// restore marker and whatever the process has printed since. Without this,
  /// [_encoded] has no entry for it and the structural save that follows
  /// re-encodes the *whole* buffer to discover what the store is already
  /// holding: measured at 2.9-5.8 ms for one pane at a full durable window,
  /// on the UI isolate, inside the button's `onPressed`.
  ///
  /// Seeding it is the trade [persistStructure] already documents and no other
  /// one: the shape is written now, the text the save writes is the text the
  /// pane already had, and the pane stays **dirty** so the autosave refreshes
  /// it on its catch-up cadence about a second later. What is deferred is the
  /// restore marker and a second of output, against the 20 s the autosave's
  /// idle interval already bounds; what is not deferred is anything
  /// structural.
  void _seedEncoding(String paneId, String? scrollback) {
    if (scrollback == null) return;
    _encoded[paneId] = scrollback;
    _markDirty(paneId);
  }

  /// What persistence currently owes, and what the last write cost.
  ///
  /// Read by Settings → Diagnostics. Built on demand rather than published,
  /// because a value that changed whenever a pane's buffer moved would rebuild
  /// a settings page from the terminal's hot path.
  ///
  /// The one question it exists to answer is whether the autosave is keeping
  /// up: a dirty count that does not fall, or an oldest-unsaved age that keeps
  /// climbing, is the shape of "my work is not being written" — which is the
  /// class of problem that was previously invisible until a layout came
  /// back missing output.
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

  /// Re-encodes the panes whose buffers changed, **for at most [budget] of
  /// main-isolate time**, returning the pane ids written.
  ///
  /// This is the autosave tick, and the budget is the whole point of it. The
  /// app's scale target is 100 live terminals, and
  /// saving every dirty pane on one tick is work proportional to *all* panes on
  /// a timer — measured at 9 ms for one pane, 57 ms for ten and **645 ms for a
  /// hundred** (`tool/benchmark/terminal_scale_bench.dart`), landing in a single
  /// freeze on the UI isolate. Capping the batch makes a tick cost the same
  /// whatever N is; whatever is left stays dirty and the autosave comes back in
  /// a second for it, so the isolate gives up a bounded slice per second instead
  /// of stalling every twenty.
  ///
  /// At least one pane is always written, so a pane that alone costs more than
  /// the budget still makes progress rather than starving.
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
          // A pane that has gone owes nothing; drop it rather than retrying it
          // on every tick from here to shutdown.
          _markClean(paneId);
          continue;
        }
        dao.saveScrollback(paneId, _scrollbackOf(paneId, instance));
        written.add(paneId);
        if (spent.elapsed >= budget) break;
      }
      // Recorded even for a run that hit its budget: a write that keeps being
      // cut off is exactly what the diagnostics page is for.
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

  /// This pane's scrollback, encoding it only if its buffer moved.
  ///
  /// Encoding is the expensive half of a save (the codec walks every line and
  /// emits an SGR run per style change), so the cache is what keeps a save
  /// proportional to what changed rather than to how much is open.
  ///
  /// With [refresh] false the cache is used **even for a dirty pane**, and the
  /// pane stays dirty: the caller is a structural save, which wants the shape
  /// written now and is content for the text to arrive on the autosave's next
  /// budgeted tick. See [persistStructure]. A pane with nothing cached is still
  /// encoded — a save never invents text it does not have.
  String _scrollbackOf(
    String paneId,
    TerminalInstance instance, {
    bool refresh = true,
  }) {
    // Two panes already hold their scrollback as text, and re-encoding a buffer
    // to get it back would be both slower and wrong. A **parked** pane gave its
    // buffer up when it went cold, so the window it kept is its scrollback and
    // nothing has been parsed into it since. A **dormant** pane is replayed
    // history with no process: what was restored is what should be stored, with
    // no second round-trip through the codec — and asking for it never builds
    // the buffer the restore did not build.
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
    // Written, so no longer owed a write. Clearing per pane rather than in bulk
    // means a pane that was somehow not persisted keeps its flag, which is the
    // safe direction to be wrong in.
    _markClean(paneId);
    return encoded;
  }

  /// A tab as a stored row.
  ///
  /// The directory stored is where the pane **ended up**, not where it was
  /// launched: `TerminalInstance.workingDirectory` follows the shell's OSC 7.
  /// That is the right one on every count — the scrollback that comes back with
  /// it was produced there, so a relative path in it resolves against the
  /// directory it was printed in; the tab comes back with the label it had; and
  /// the launch directory is an artefact of how the pane happened to be opened,
  /// which the user has since moved away from on purpose. It cannot start
  /// anything either: a restored pane is a record, and this only decides where
  /// a shell would spawn *if* the user presses Start — never whether one does,
  /// and never a command re-run.
  ///
  /// An **empty region** has no instance, so it stores no pane — and restore's
  /// `withoutMissing` drops the leaf that named it. That is deliberate: a
  /// region is room the user cleared for something, and a reboot has already
  /// taken away everything that could have gone in it. The layout comes back
  /// holding what actually exists.
  StoredTerminalTab _storedTab(TerminalTab tab, {required bool refresh}) {
    return StoredTerminalTab(
      id: tab.id,
      layout: tab.layout,
      focusedPaneId: tab.focusedPaneId,
      panes: [
        for (final paneId in tab.layout.panes)
          if (_instances[paneId] case final instance?)
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

  /// A detached session as a single-pane, tab-less row.
  ///
  /// Its id is derived from the pane so repeated saves overwrite rather than
  /// accumulate. Returns null if the instance has gone since it was detached.
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

/// The parsed buffer [instance] can hand to the pane that replaces it, if it
/// has one.
///
/// Asked **before** [_heldScrollbackOf], because a buffer that already exists
/// is strictly cheaper than any text: taking it costs nothing, where the text
/// costs a parse — and, for a pane whose process merely exited, an encode
/// first. See [AdoptableTerminalInstance] for what declines.
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
