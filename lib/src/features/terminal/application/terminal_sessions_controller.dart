import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../settings/application/settings_controller.dart';
import '../data/scrollback_codec.dart';
import '../data/terminal_instance.dart';
import '../data/terminal_workspace_dao.dart';
import '../domain/agent_pane_launch.dart';
import '../domain/ingest_tier.dart';
import '../domain/pane_layout.dart';
import '../domain/pane_liveness.dart';
import '../domain/terminal_profile.dart';
import 'scrollback_autosave.dart';

/// Whether new panes get OSC 133 shell integration.
///
/// A provider of its own rather than an inline settings read, so a test that
/// only wants a terminal does not have to stand up a database to get one —
/// the same seam `terminalInstanceFactoryProvider` already provides.
final shellIntegrationEnabledProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider).shellIntegrationEnabled,
);

/// The production factory: each pane is backed by a real ConPTY.
final terminalInstanceFactoryProvider = Provider<TerminalInstanceFactory>(
  (ref) => createPtyTerminalInstance,
);

/// One tab: a tree of panes and which of them has focus.
class TerminalTab {
  const TerminalTab({
    required this.id,
    required this.layout,
    required this.focusedPaneId,
  });

  final String id;
  final PaneLayout layout;
  final String focusedPaneId;

  TerminalTab copyWith({PaneLayout? layout, String? focusedPaneId}) {
    return TerminalTab(
      id: id,
      layout: layout ?? this.layout,
      focusedPaneId: focusedPaneId ?? this.focusedPaneId,
    );
  }
}

/// A session whose view was closed but whose process was left running.
///
/// This is what separates session lifetime from view lifetime: closing a tab
/// removes the *view*, and the build, dev server or agent inside carries on in
/// the background until the user ends it or the app quits.
class DetachedSession {
  const DetachedSession({
    required this.paneId,
    required this.title,
    required this.workingDirectory,
    required this.detachedAt,
  });

  final String paneId;
  final String title;
  final String? workingDirectory;
  final DateTime detachedAt;
}

/// Open terminal tabs, which one is active, the sessions running with no tab,
/// and whether each pane actually has a process behind it.
class TerminalSessionsState {
  const TerminalSessionsState({
    this.tabs = const [],
    this.activeTabId,
    this.detached = const [],
    this.liveness = const {},
  });

  final List<TerminalTab> tabs;
  final String? activeTabId;

  /// Sessions kept running with no tab showing them, newest last.
  final List<DetachedSession> detached;

  /// Per-pane liveness, republished whenever a process exits — so a pane that
  /// died while its tab was in the background still repaints as dead.
  final Map<String, PaneLiveness> liveness;

  bool get isEmpty => tabs.isEmpty;

  /// Liveness of [paneId]. An unknown pane is treated as not running: the
  /// safe answer, since the only way to be live is to be tracked.
  PaneLiveness livenessOf(String paneId) =>
      liveness[paneId] ?? PaneLiveness.exited;

  TerminalTab? get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab;
    }
    return null;
  }
}

/// Manages open terminal tabs, the split tree inside each, which pane has focus,
/// and persisting the whole workspace so it survives a restart.
///
/// The tab list and live instances are the controller's **own fields**, with
/// [state] published from them. Riverpod forbids reading `state` inside `build`
/// and `onDispose`, and both restore (which runs during build) and the final
/// snapshot (which runs during dispose) need the tabs.
class TerminalSessionsController extends Notifier<TerminalSessionsState> {
  final List<TerminalTab> _tabs = [];
  String? _activeTabId;

  final Map<String, TerminalInstance> _instances = {};

  /// Sessions with a running process and no tab, oldest first.
  final List<DetachedSession> _detached = [];

  /// Panes whose buffer changed since their last snapshot.
  final Set<String> _dirty = {};

  /// The last encoding written for each pane.
  ///
  /// A pane that is not in [_dirty] has not touched its buffer since this was
  /// produced, so re-running the encoder on it can only produce the same string.
  /// Keeping it turns a workspace save from "re-encode every pane" into "encode
  /// the ones that changed" — which is what makes a save on every structural
  /// change (open, split, close, detach) affordable, and what makes the save on
  /// quit a delta over the last autosave tick rather than a full re-encode of
  /// every open pane.
  final Map<String, String> _encoded = {};

  /// Per-pane buffer listeners, kept so they can be removed on close.
  final Map<String, void Function()> _dirtyListeners = {};

  /// Per-pane liveness listeners, kept for the same reason.
  final Map<String, void Function()> _livenessListeners = {};

  /// Whether the user has closed a tab, a pane or a session since the workspace
  /// was restored.
  ///
  /// An empty workspace has two causes that the store cannot tell apart, and
  /// only one of them is a fact worth writing down. *The user closed everything*
  /// is a decision, and clearing the store is the correct outcome — Loop 29's
  /// behaviour, and tested. *We momentarily have nothing* is a bug, and since
  /// [persistWorkspace] is a destructive full replace, writing it destroys the
  /// user's workspace outright; Loop 48 watched that happen once in ten real
  /// runs and never found the trigger.
  ///
  /// So the controller keeps the one piece of information the database cannot
  /// reconstruct: whether anything the *user* did could account for the
  /// emptiness. Nothing else sets this flag — a pane exiting on its own does
  /// not, because a dead pane still has a row worth restoring.
  bool _userClosedSinceRestore = false;

  late final ScrollbackAutosave _autosave = ref.read(
    scrollbackAutosaveFactoryProvider,
  )(
    onTick: () {
      saveDirtyScrollback();
      return hasDirtyScrollback;
    },
  );

  final _log = AppLogger.named('terminal');

  /// Whether [shutdownProcesses] has already run.
  ///
  /// It empties [_tabs], so the container's own teardown must not persist
  /// afterwards: it would write that emptiness over the workspace the user
  /// expects back.
  bool _processesShutDown = false;

  /// Set on teardown, so a post-frame callback that outlives the container
  /// cannot touch a disposed pane. See [_afterFrame].
  bool _disposed = false;

  @override
  TerminalSessionsState build() {
    ref.onDispose(() {
      _disposed = true;
      _autosave.stop();
      if (_processesShutDown) return;
      persistWorkspace();
      _disposeAll();
    });
    _restoreWorkspace();
    _autosave.start();
    return _snapshot();
  }

  /// Ends every pane's process and completes when the kills have landed.
  ///
  /// The teardown `ref.onDispose` runs is synchronous: it asks each pane to
  /// dispose and moves on. On Windows disposing a pane spawns a
  /// `taskkill /PID <pid> /T /F`, so on quit those spawns were still in flight
  /// when `windowManager.destroy()` ended the process — and everything running
  /// inside the panes (a dev server holding a port, a build holding a file
  /// lock) was orphaned. This is the same teardown, awaitable, so the shutdown
  /// sequence can wait for it inside its budget.
  ///
  /// Idempotent, and the container's own teardown stands down once it has run.
  Future<void> shutdownProcesses() async {
    if (_processesShutDown) return;
    _processesShutDown = true;
    _autosave.stop();
    persistWorkspace();
    await Future.wait(_disposeAll());
  }

  TerminalSessionsState _snapshot() => TerminalSessionsState(
    tabs: List.of(_tabs),
    activeTabId: _activeTabId,
    detached: List.of(_detached),
    liveness: {
      for (final entry in _instances.entries)
        entry.key: entry.value.liveness.value,
    },
  );

  void _publish() {
    _applyIngestTiers();
    state = _snapshot();
  }

  /// Tells every pane how visible it is, so ingestion can cost what the pane is
  /// worth rather than the same for all of them.
  ///
  /// The workspace is the only thing that knows this, which is why it lives
  /// here and not in the pane: a pane cannot see which tab is in front. Called
  /// from [_publish], so every open, close, split, activate, detach and
  /// reattach re-derives it from one place — there is no second path that could
  /// leave a pane at the wrong tier.
  ///
  /// * **hot** — every pane of the active tab, focused or not: they are all on
  ///   screen.
  /// * **warm** — panes of every other open tab. Correct, but not watched.
  /// * **cold** — anything still tracked with no tab at all, which is a
  ///   detached session. Not parsed; its output spools.
  ///
  /// Cost is O(panes) per publish and every pane whose tier did not change
  /// returns immediately, which is nearly all of them nearly always.
  void _applyIngestTiers() {
    final tiers = <String, IngestTier>{};
    for (final tab in _tabs) {
      final tier = tab.id == _activeTabId ? IngestTier.hot : IngestTier.warm;
      for (final paneId in tab.layout.panes) {
        tiers[paneId] = tier;
      }
    }
    for (final entry in _instances.entries) {
      if (entry.value case final TieredTerminalInstance tiered) {
        tiered.setIngestTier(tiers[entry.key] ?? IngestTier.cold);
      }
    }
  }

  /// Disposes every pane, returning the reaps still in flight — one per pane
  /// that owns a process. Callers that can wait should; `ref.onDispose` cannot.
  List<Future<void>> _disposeAll() {
    final reaping = <Future<void>>[];
    for (final entry in _instances.entries) {
      _unlisten(entry.key, entry.value);
      entry.value.dispose();
      if (entry.value case final ReapableTerminalInstance reapable) {
        reaping.add(reapable.reaped);
      }
    }
    _instances.clear();
    _dirtyListeners.clear();
    _livenessListeners.clear();
    _dirty.clear();
    _encoded.clear();
    _tabs.clear();
    _detached.clear();
    _activeTabId = null;
    return reaping;
  }

  /// The live terminal behind [paneId], or `null` once it has been closed.
  TerminalInstance? instanceFor(String paneId) => _instances[paneId];

  /// Opens a new tab running [profile] and makes it active. Returns its id.
  String openTab(TerminalProfile profile, {String? workingDirectory}) {
    final tabId = _newId();
    final paneId = _createPane(profile, workingDirectory: workingDirectory);
    _tabs.add(
      TerminalTab(
        id: tabId,
        layout: PaneLayout.single(paneId),
        focusedPaneId: paneId,
      ),
    );
    _activeTabId = tabId;
    _publish();
    persistWorkspace();
    _focusActivePane();
    return tabId;
  }

  /// Opens a new tab running an agent CLI in a PTY and makes it active.
  ///
  /// This is what makes any registry agent usable without a protocol adapter:
  /// the pane is an ordinary terminal, so keep-alive, detach/reattach, scrollback
  /// persistence, search and the split tree all apply to an agent exactly as
  /// they do to a shell. Returns the new pane's id.
  ({String tabId, String paneId}) openAgentTab(AgentPaneLaunch launch) {
    final tabId = _newId();
    final paneId = _newId();
    _adopt(
      paneId,
      ref.read(terminalInstanceFactoryProvider)(
        id: paneId,
        // Unused for an agent pane, but the factory's contract requires one and
        // a bogus profile would be worse than the host default.
        profile: TerminalProfile.powerShell,
        workingDirectory: launch.workingDirectory,
        agentLaunch: launch,
      ),
    );
    _tabs.add(
      TerminalTab(
        id: tabId,
        layout: PaneLayout.single(paneId),
        focusedPaneId: paneId,
      ),
    );
    _activeTabId = tabId;
    _publish();
    persistWorkspace();
    _focusActivePane();
    return (tabId: tabId, paneId: paneId);
  }

  void activateTab(String id) {
    if (_activeTabId == id) return;
    _activeTabId = id;
    _publish();
    _focusActivePane();
  }

  /// Closes tab [id].
  ///
  /// Closing a tab is a *view* action, so by default every pane in it that still
  /// has a running process is detached rather than killed — the whole point of
  /// keep-alive. Panes with nothing running behind them are simply dropped;
  /// there is no session there to keep. Pass `detach: false` to end them for
  /// real, which is what "End session" does.
  void closeTab(String id, {bool detach = true}) {
    final tab = _tabById(id);
    if (tab == null) return;
    _userClosedSinceRestore = true;
    for (final paneId in tab.layout.panes) {
      if (detach) {
        _detachOrRelease(paneId);
      } else {
        _releasePane(paneId);
      }
    }
    _tabs.removeWhere((t) => t.id == id);
    if (_activeTabId == id) {
      _activeTabId = _tabs.isEmpty ? null : _tabs.last.id;
    }
    _publish();
    persistWorkspace();
    // Closing the active tab hands the keyboard to whichever tab took its
    // place, rather than leaving it nowhere.
    _focusActivePane();
  }

  /// Splits the active tab's focused pane along [axis], running [profile] in the
  /// new pane and focusing it. Returns the new pane id, or `null` if no tab is
  /// open.
  String? splitPane(
    SplitAxis axis,
    TerminalProfile profile, {
    String? workingDirectory,
  }) {
    final tab = _activeTab;
    if (tab == null) return null;

    final paneId = _createPane(profile, workingDirectory: workingDirectory);
    _replaceTab(
      tab.copyWith(
        layout: tab.layout.split(tab.focusedPaneId, axis, paneId, _newId()),
        focusedPaneId: paneId,
      ),
    );
    _focusActivePane();
    persistWorkspace();
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
    if (layout == null) {
      closeTab(tab.id, detach: detach);
      return;
    }

    if (detach) {
      _detachOrRelease(paneId);
    } else {
      _releasePane(paneId);
    }
    _replaceTab(
      tab.copyWith(
        layout: layout,
        focusedPaneId: layout.contains(tab.focusedPaneId)
            ? tab.focusedPaneId
            : layout.panes.first,
      ),
    );
    _focusActivePane();
    persistWorkspace();
  }

  /// Moves [delta] (a fraction of the split's extent) from child `index + 1` to
  /// child [index] of split [splitId] in tab [tabId].
  void resizePane(String tabId, String splitId, int index, double delta) {
    final tab = _tabById(tabId);
    if (tab == null) return;
    _replaceTab(tab.copyWith(layout: tab.layout.resize(splitId, index, delta)));
  }

  /// Focuses [paneId], activating the tab that holds it.
  void focusPane(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null) return;
    _activeTabId = tab.id;
    _replaceTab(tab.copyWith(focusedPaneId: paneId));
    _focusActivePane();
  }

  /// Moves focus to the pane adjacent to the focused one in [direction].
  void movePaneFocus(PaneDirection direction) {
    final tab = _activeTab;
    if (tab == null) return;
    final target = tab.layout.paneInDirection(tab.focusedPaneId, direction);
    if (target != null) focusPane(target);
  }

  void nextTab() => _stepTab(1);

  void previousTab() => _stepTab(-1);

  /// The label shown on tab [tabId]: the focused pane's title, plus the pane
  /// count once the tab holds more than one.
  String titleForTab(String tabId) {
    final tab = _tabById(tabId);
    if (tab == null) return 'Terminal';
    final title = _instances[tab.focusedPaneId]?.title ?? 'Terminal';
    final count = tab.layout.panes.length;
    return count > 1 ? '$title ($count)' : title;
  }

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

  // --- session lifetime ------------------------------------------------------

  /// Brings a detached session back as a new tab and focuses it.
  ///
  /// Returns the new tab's id, or `null` if nothing was detached under
  /// [paneId]. The instance is the *same object* that was running all along, so
  /// re-attaching is instantaneous and loses nothing — this is a view being
  /// reopened, not a session being recreated.
  String? reattachSession(String paneId) {
    final index = _detached.indexWhere((s) => s.paneId == paneId);
    if (index < 0) return null;
    _detached.removeAt(index);

    final tabId = _newId();
    _tabs.add(
      TerminalTab(
        id: tabId,
        layout: PaneLayout.single(paneId),
        focusedPaneId: paneId,
      ),
    );
    _activeTabId = tabId;
    _publish();
    persistWorkspace();
    _focusActivePane();
    return tabId;
  }

  /// Ends session [paneId] for real — the deliberate counterpart to closing its
  /// tab.
  ///
  /// The process is asked to exit and then killed if it will not (Loop 32's
  /// escalation, via the instance's `dispose`). Works whether the pane is in a
  /// tab or detached.
  void endSession(String paneId) {
    _userClosedSinceRestore = true;
    if (_tabContaining(paneId) != null) {
      closePane(paneId, detach: false);
      return;
    }
    _detached.removeWhere((s) => s.paneId == paneId);
    _releasePane(paneId);
    _publish();
    persistWorkspace();
  }

  /// Ends every detached session at once — the "I am done with all of these"
  /// escape hatch, so background sessions can never quietly pile up.
  void endAllDetached() {
    if (_detached.isEmpty) return;
    _userClosedSinceRestore = true;
    for (final session in List.of(_detached)) {
      _releasePane(session.paneId);
    }
    _detached.clear();
    _publish();
    persistWorkspace();
  }

  /// Starts a process in [paneId], replaying whatever is already in its buffer
  /// above the new one.
  ///
  /// This is the *only* way a restored pane gets a process: nothing runs at
  /// launch, so restarting the app can never re-execute a build or an agent
  /// behind the user's back. Also the retry path for a pane whose process
  /// exited or failed to spawn.
  ///
  /// Does nothing for a pane that is already live.
  void startPane(String paneId) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return;
    // An agent pane is restarted from its recorded command, not from a shell
    // profile: `agent:<id>` deliberately does not resolve as one.
    final agentLaunch = existing.agentLaunch;
    final profile = agentLaunch != null
        ? TerminalProfile.powerShell
        : terminalProfileFromId(existing.profileId);
    if (profile == null) return;

    // A dormant pane hands back exactly what was restored; a pane whose process
    // exited has to be re-encoded, because its buffer has moved on since.
    final scrollback = existing is DormantTerminalInstance
        ? existing.restoredScrollback
        : encodeScrollback(existing.terminal);
    final workingDirectory = existing.workingDirectory;

    _releasePane(paneId);
    _adopt(
      paneId,
      ref.read(terminalInstanceFactoryProvider)(
        id: paneId,
        profile: profile,
        workingDirectory: workingDirectory,
        restoredScrollback: scrollback,
        shellIntegration: _shellIntegrationEnabled,
        agentLaunch: agentLaunch,
      ),
    );
    _publish();
    persistWorkspace();
    _focusActivePane();
  }

  // --- persistence -----------------------------------------------------------

  /// Writes the whole workspace — tabs, layouts, detached sessions and every
  /// pane's scrollback.
  ///
  /// Runs on every structural change (open, split, close, detach, end, start)
  /// and on teardown. The container *is* disposed on quit now (Loop 61's
  /// lifecycle owner), but that happens inside a bounded budget several steps
  /// in, and `windowManager.destroy()` ends the process the moment the sequence
  /// returns — so anything not already written when the user quits is still
  /// simply gone. The 20 s autosave covers scrollback between those points.
  ///
  /// Does nothing when no database is wired up (tests, and any bootstrap that
  /// has not opened one).
  ///
  /// Also does nothing when it would replace a non-empty stored workspace with
  /// an empty one that no user action accounts for — see
  /// [_userClosedSinceRestore]. That case is a bug by construction, and the
  /// difference between a bug and a data loss is whether the bug is allowed to
  /// write.
  void persistWorkspace() {
    final dao = _dao();
    if (dao == null) return;
    try {
      final rows = [
        for (final tab in _tabs) _storedTab(tab),
        for (final session in _detached) ?_storedDetached(session),
      ];
      if (rows.isEmpty && !_userClosedSinceRestore) {
        final stored = dao.storedTabCount();
        if (stored > 0) {
          _log.error(
            'Refusing to save an empty terminal workspace over $stored stored '
            'tab(s): nothing the user closed accounts for it being empty. The '
            'stored workspace is left untouched. This should not happen — if '
            'the terminal really is empty, please report it.',
          );
          return;
        }
      }
      dao.saveWorkspace(
        rows,
        activeTabId: _activeTabId,
        userClosed: _userClosedSinceRestore,
      );
    } catch (error, stack) {
      _log.warning('Could not persist the terminal workspace.', error, stack);
    }
  }

  /// Whether any pane still owes a scrollback write.
  ///
  /// What tells [ScrollbackAutosave] to come back on its catch-up cadence
  /// rather than its idle one.
  bool get hasDirtyScrollback => _dirty.isNotEmpty;

  /// Re-encodes the panes whose buffers changed, **for at most [budget] of
  /// main-isolate time**, returning the pane ids written.
  ///
  /// This is the autosave tick, and the budget is the whole point of it. The
  /// app's scale target is 100 live terminals (`docs/ARCHITECTURE.md`), and
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
      for (final paneId in _dirty.toList()) {
        final instance = _instances[paneId];
        if (instance == null) {
          // A pane that has gone owes nothing; drop it rather than retrying it
          // on every tick from here to shutdown.
          _dirty.remove(paneId);
          continue;
        }
        dao.saveScrollback(paneId, _scrollbackOf(paneId, instance));
        written.add(paneId);
        if (spent.elapsed >= budget) break;
      }
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
  String _scrollbackOf(String paneId, TerminalInstance instance) {
    if (!_dirty.contains(paneId)) {
      final cached = _encoded[paneId];
      if (cached != null) return cached;
    }
    final encoded = encodeScrollback(instance.terminal);
    _encoded[paneId] = encoded;
    // Written, so no longer owed a write. Clearing per pane rather than in bulk
    // means a pane that was somehow not persisted keeps its flag, which is the
    // safe direction to be wrong in.
    _dirty.remove(paneId);
    return encoded;
  }

  StoredTerminalTab _storedTab(TerminalTab tab) {
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
              scrollback: _scrollbackOf(paneId, instance),
              agentLaunch: instance.agentLaunch,
            ),
      ],
    );
  }

  /// A detached session as a single-pane, tab-less row.
  ///
  /// Its id is derived from the pane so repeated saves overwrite rather than
  /// accumulate. Returns null if the instance has gone since it was detached.
  StoredTerminalTab? _storedDetached(DetachedSession session) {
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
          scrollback: _scrollbackOf(session.paneId, instance),
          agentLaunch: instance.agentLaunch,
        ),
      ],
    );
  }

  /// Recreates the stored workspace: the tabs, the splits inside them, and each
  /// pane's scrollback replayed into a **dormant** buffer.
  ///
  /// No process is started. A reboot ends every process regardless, so a stored
  /// pane is a record, not a session — and spawning something for each one at
  /// launch would both re-execute work the user never asked to repeat and make
  /// week-old history indistinguishable from a live shell. Each pane instead
  /// comes back marked as restored, with an explicit start.
  ///
  /// Defensive at every step: a layout that will not parse, a pane whose profile
  /// no longer exists, a tab left with nothing in it — each is dropped rather
  /// than thrown on, because a corrupt row must never make the terminal
  /// unopenable. The worst case is an empty workspace, which is what a first run
  /// looks like anyway.
  void _restoreWorkspace() {
    // Whatever the previous life of this controller decided about closing
    // things, this one starts owing the store the workspace it just read.
    _userClosedSinceRestore = false;
    final dao = _dao();
    if (dao == null) return;

    try {
      final stored = dao.loadWorkspace();
      for (final storedTab in stored.tabs) {
        final rebuilt = <String>{};
        for (final pane in storedTab.panes) {
          if (!storedTab.layout.contains(pane.id)) continue;
          if (_adoptDormant(pane)) rebuilt.add(pane.id);
        }

        final layout = storedTab.layout.withoutMissing(rebuilt);
        if (layout == null) continue;
        final stayed = storedTab.focusedPaneId;
        _tabs.add(
          TerminalTab(
            id: storedTab.id,
            layout: layout,
            focusedPaneId: (stayed != null && layout.contains(stayed))
                ? stayed
                : layout.panes.first,
          ),
        );
        if (storedTab.id == stored.activeTabId) _activeTabId = storedTab.id;
      }

      // Sessions that had no tab last time stay tab-less: they come back in the
      // background list, where the user reopens the ones still worth having.
      for (final storedTab in stored.detached) {
        for (final pane in storedTab.panes) {
          if (!_adoptDormant(pane)) continue;
          _detached.add(
            DetachedSession(
              paneId: pane.id,
              title: pane.title,
              workingDirectory: pane.workingDirectory,
              detachedAt: ref.read(clockProvider).nowUtc(),
            ),
          );
        }
      }

      _activeTabId ??= _tabs.isEmpty ? null : _tabs.last.id;
    } catch (error, stack) {
      _log.warning('Could not restore the terminal workspace.', error, stack);
    }
  }

  /// Rebuilds [pane] as a process-free buffer holding its stored scrollback.
  ///
  /// Returns false when the pane's profile no longer resolves — a WSL distro
  /// that has been removed, say — since there would be nothing to start it with.
  bool _adoptDormant(StoredTerminalPane pane) {
    // An agent pane carries its own command, so it does not need — and never
    // had — a resolvable shell profile.
    if (pane.agentLaunch == null &&
        terminalProfileFromId(pane.profileId) == null) {
      return false;
    }
    _adopt(
      pane.id,
      DormantTerminalInstance(
        id: pane.id,
        title: pane.title,
        profileId: pane.profileId,
        workingDirectory: pane.workingDirectory,
        restoredScrollback: pane.scrollback,
        agentLaunch: pane.agentLaunch,
      ),
    );
    return true;
  }

  /// The workspace DAO, or `null` when no database is wired up.
  TerminalWorkspaceDao? _dao() {
    try {
      return ref.read(terminalWorkspaceDaoProvider);
    } catch (_) {
      return null;
    }
  }

  // --- internals -------------------------------------------------------------

  String _newId() => ref.read(idGeneratorProvider).newId();

  TerminalTab? get _activeTab => _tabById(_activeTabId);

  /// Read per launch rather than watched, so toggling the setting affects new
  /// panes only and never restarts a running shell underneath the user.
  bool get _shellIntegrationEnabled =>
      ref.read(shellIntegrationEnabledProvider);

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
    void markDirty() => _dirty.add(paneId);
    _dirtyListeners[paneId] = markDirty;
    instance.terminal.addListener(markDirty);
    // Republish when the process exits so the pane (and its tab, and the
    // background-session list) stops presenting itself as live. One rebuild per
    // process death — not per frame — so this costs nothing.
    void onLiveness() => _publish();
    _livenessListeners[paneId] = onLiveness;
    instance.liveness.addListener(onLiveness);
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
    if (!instance.liveness.value.isLive) {
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
  }

  /// Disposes the pane [paneId] owns and stops tracking it.
  void _releasePane(String paneId) {
    final instance = _instances.remove(paneId);
    if (instance == null) return;
    _unlisten(paneId, instance);
    _dirty.remove(paneId);
    _encoded.remove(paneId);
    instance.dispose();
  }

  /// Drops the listeners [_adopt] attached, so a disposed instance can never
  /// call back into the controller.
  void _unlisten(String paneId, TerminalInstance instance) {
    final dirty = _dirtyListeners.remove(paneId);
    if (dirty != null) instance.terminal.removeListener(dirty);
    final liveness = _livenessListeners.remove(paneId);
    if (liveness != null) instance.liveness.removeListener(liveness);
  }

  TerminalTab? _tabById(String? id) {
    if (id == null) return null;
    for (final tab in _tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  TerminalTab? _tabContaining(String paneId) {
    for (final tab in _tabs) {
      if (tab.layout.contains(paneId)) return tab;
    }
    return null;
  }

  void _replaceTab(TerminalTab updated) {
    final index = _tabs.indexWhere((tab) => tab.id == updated.id);
    if (index < 0) return;
    _tabs[index] = updated;
    _publish();
  }

  void _stepTab(int by) {
    if (_tabs.length < 2) return;
    final index = _tabs.indexWhere((tab) => tab.id == _activeTabId);
    if (index < 0) return;
    activateTab(_tabs[(index + by + _tabs.length) % _tabs.length].id);
  }

  /// Gives the active tab's focused pane the keyboard, so a pane that has just
  /// become the active one is typable without a click.
  ///
  /// **Deferred to after the frame, and that is the whole point.** The panes
  /// live in an [IndexedStack], which wraps every child but the selected one in
  /// an `ExcludeFocus` (`packages/flutter/lib/src/widgets/indexed_stack.dart:108`).
  /// Publishing a new active tab only marks the widget tree dirty, so at the
  /// moment these callers run, the pane being switched *to* is still inside
  /// that `ExcludeFocus` and `requestFocus()` is silently dropped. Waiting for
  /// the rebuild that selects it is what makes the request stick.
  ///
  /// The pane is re-resolved inside the callback, so a burst of tab switches
  /// leaves the keyboard on the tab the user actually landed on.
  void _focusActivePane() {
    _afterFrame(() {
      final tab = _activeTab;
      if (tab == null) return;
      final node = _instances[tab.focusedPaneId]?.focusNode;
      if (node == null || node.hasFocus) return;
      // Never out of a text field the user is typing in — quick open, the
      // search bar, a composer, a dialog. Opening or closing a terminal tab is
      // not worth taking the keyboard away from what someone is writing.
      if (_keyboardIsInATextField()) return;
      node.requestFocus();
    });
  }

  /// Runs [action] once the pending rebuild has been laid out.
  ///
  /// A no-op with no binding at all, which is what a controller-only test is:
  /// there is no widget tree, so there is no focus to move. A post-frame
  /// callback, unlike a timer, does not trip `flutter_test`'s pending-work
  /// checks when no frame ever comes.
  void _afterFrame(void Function() action) {
    final binding = _bindingOrNull();
    if (binding == null) return;
    binding.addPostFrameCallback((_) {
      if (_disposed) return;
      action();
    });
  }

  /// The widget binding, or null when there is none.
  ///
  /// `WidgetsBinding.instance` throws rather than returning null, and the
  /// controller is deliberately usable without a widget tree — most of its own
  /// tests drive it that way — so the throw is the check.
  static WidgetsBinding? _bindingOrNull() {
    try {
      return WidgetsBinding.instance;
    } catch (_) {
      return null;
    }
  }

  /// Whether the keyboard currently belongs to a text field.
  static bool _keyboardIsInATextField() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}

final terminalSessionsControllerProvider =
    NotifierProvider<TerminalSessionsController, TerminalSessionsState>(
      TerminalSessionsController.new,
    );

/// Whether the terminal panel is visible.
class TerminalVisibleController extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
  void set(bool value) => state = value;
}

final terminalVisibleProvider =
    NotifierProvider<TerminalVisibleController, bool>(
      TerminalVisibleController.new,
    );

/// Whether the terminal fills the whole window rather than sitting in its dock.
class TerminalMaximizedController extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final terminalMaximizedProvider =
    NotifierProvider<TerminalMaximizedController, bool>(
      TerminalMaximizedController.new,
    );
