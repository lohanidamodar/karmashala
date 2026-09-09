import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/widgets/keyboard_capture.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../env_secrets/application/env_secrets_controller.dart';
import '../../sessions/application/session_mcp_arguments.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../ssh/application/host_session_providers.dart';
import '../../ssh/application/ssh_providers.dart';
import '../data/host_terminal_instance.dart';
import '../data/pty_launch.dart';
import '../data/scrollback_codec.dart';
import '../data/ssh_terminal_instance.dart';
import '../data/terminal_grid_text.dart';
import '../data/terminal_instance.dart';
import '../data/terminal_layout_dao.dart';
import '../domain/agent_pane_launch.dart';
import '../domain/detach_policy.dart';
import '../domain/ingest_tier.dart';
import '../domain/pane_layout.dart';
import '../domain/workspace_layout.dart';
import '../domain/pane_liveness.dart';
import '../domain/persistence_telemetry.dart';
import '../domain/pane_restart.dart';
import '../domain/pane_title.dart';
import '../domain/terminal_preset.dart';
import '../domain/terminal_profile.dart';
import 'local_host_providers.dart';
import 'pane_exit_signal.dart';
import 'scrollback_autosave.dart';
import 'terminal_profiles.dart';

part 'terminal_sessions_state.dart';
part 'terminal_instance_factory.dart';
part 'terminal_sessions_providers.dart';
part 'terminal_sessions_tabs.dart';
part 'terminal_sessions_groups.dart';
part 'terminal_sessions_regions.dart';
part 'terminal_sessions_presets.dart';
part 'terminal_sessions_panes.dart';
part 'terminal_sessions_titles.dart';
part 'terminal_sessions_lifetime.dart';
part 'terminal_sessions_persistence.dart';

/// Manages open terminal tabs, the split tree inside each, which pane has focus,
/// and persisting the whole layout so it survives a restart.
///
/// The tab list and live instances are the controller's **own fields**, with
/// [state] published from them. Riverpod forbids reading `state` inside `build`
/// and `onDispose`, and both restore (which runs during build) and the final
/// snapshot (which runs during dispose) need the tabs.
class TerminalSessionsController extends Notifier<TerminalSessionsState> {
  final List<TerminalTab> _tabs = [];
  String? _activeTabId;

  /// The workspace split tree — see [WorkspaceLayout]. Kept in step with
  /// [_tabs] by [_reconcileWorkspace] rather than by every tab verb.
  WorkspaceLayout? _workspace;

  /// The group [_activeTabId] belongs to, or the empty group the user split
  /// into and has not filled yet.
  String? _focusedGroupId;

  /// The tree the store already holds, so a save that changed no group writes
  /// no row — the same record [_writtenGrid] keeps for the grid hint.
  WorkspaceLayout? _writtenWorkspace;

  final Map<String, TerminalInstance> _instances = {};

  /// Sessions with a running process and no tab, oldest first.
  final List<DetachedSession> _detached = [];

  /// The published projections of [_tabs], [_detached] and the instances'
  /// liveness, plus the two id indexes derived from the tab list.
  ///
  /// All null until asked for, and nulled only by the thing they are derived
  /// from changing — so a publish that moved one pane's liveness hands the
  /// *same* tab list back to consumers, and "which tab holds this pane?" is a
  /// map lookup rather than a scan over every tab that allocated a pane list
  /// per tab as it went.
  List<TerminalTab>? _tabsView;
  List<DetachedSession>? _detachedView;
  Map<String, PaneLiveness>? _livenessView;
  Map<String, String?>? _directoriesView;
  Map<String, int>? _tabIndexById;
  Map<String, String>? _tabIdByPane;

  /// Panes whose buffer changed since their last snapshot.
  final Set<String> _dirty = {};

  /// When each dirty pane *became* dirty, on [_uptime]'s monotonic scale.
  ///
  /// Written only on the clean→dirty transition, which `Set.add`'s return value
  /// already reports for free: `markDirty` runs on every terminal notification
  /// of every pane, so reading a clock there would be a per-frame,
  /// per-pane cost for a number nobody reads more than once a second.
  final Map<String, Duration> _dirtySince = {};

  /// Monotonic, so an unsaved age cannot be distorted by the wall clock moving.
  final Stopwatch _uptime = Stopwatch()..start();

  /// What the last completed scrollback write cost and covered. Null until one
  /// has run — reported as "not recorded" rather than as zero.
  ScrollbackWrite? _lastWrite;

  /// Shared by every restored pane so they can tell each other how wide the
  /// workbench draws a pane, rather than each parsing its history at xterm's
  /// default 80 columns and being reflowed. See [TerminalGridHint].
  ///
  /// Seeded from the store, because the panes that most need it are the ones a
  /// restore builds: the launch frame parses every mounted tab's history during
  /// `build`, before the layout pass that would have measured the first pane.
  final TerminalGridHint _gridHint = TerminalGridHint();

  /// The grid last written to the store, so a save that would write the same
  /// value writes nothing.
  ({int columns, int rows})? _writtenGrid;

  /// The last encoding written for each pane.
  ///
  /// A pane that is not in [_dirty] has not touched its buffer since this was
  /// produced, so re-running the encoder on it can only produce the same string.
  /// Keeping it turns a layout save from "re-encode every pane" into "encode
  /// the ones that changed" — which is what makes a save on every structural
  /// change (open, split, close, detach) affordable, and what makes the save on
  /// quit a delta over the last autosave tick rather than a full re-encode of
  /// every open pane.
  final Map<String, String> _encoded = {};

  /// Per-pane buffer listeners, kept so they can be removed on close.
  final Map<String, void Function()> _dirtyListeners = {};

  /// Per-pane liveness listeners, kept for the same reason.
  final Map<String, void Function()> _livenessListeners = {};

  /// Per-pane working-directory listeners, kept for the same reason.
  final Map<String, void Function()> _directoryListeners = {};

  /// Titles panes have set for themselves with OSC 0/2, by pane id.
  ///
  /// A shell (or a TUI) naming its own window is the strongest signal there is
  /// about what a plain terminal is doing, which is why it outranks the
  /// directory. Agent panes are the exception — see [_titleForPane], and so is
  /// a pane merely reciting the launcher we started it with — see
  /// [_namesLauncher], which is why titles are filtered on the way *in* rather
  /// than on the way out.
  final Map<String, String> _oscTitles = {};

  /// Resolved tab labels, cleared on every publish.
  ///
  /// A label can cost a database read (an agent pane resolves its session's
  /// *current* name), and the tab strip asks for one per tab per build. Without
  /// this, a hundred tabs would be a hundred queries a frame.
  final Map<String, String> _titles = {};

  /// Monotonically increasing revision number incremented on every publish.
  int _titleRevision = 0;

  /// Whether the user has closed a tab, a pane or a session since the layout
  /// was restored.
  ///
  /// An empty layout has two causes that the store cannot tell apart, and
  /// only one of them is a fact worth writing down. *The user closed everything*
  /// is a decision, and clearing the store is the correct outcome — Loop 29's
  /// behaviour, and tested. *We momentarily have nothing* is a bug, and a save
  /// deletes every tab the layout no longer holds, so writing it destroys
  /// the user's layout outright; Loop 48 watched that happen once in ten
  /// real runs and never found the trigger. (A save writes only the rows that
  /// changed now, but "every tab vanished" changes every row — incremental
  /// writing narrows the cost of this failure, not its reach.)
  ///
  /// So the controller keeps the one piece of information the database cannot
  /// reconstruct: whether anything the *user* did could account for the
  /// emptiness. Nothing else sets this flag — a pane exiting on its own does
  /// not, because a dead pane still has a row worth restoring.
  bool _userClosedSinceRestore = false;

  late final ScrollbackAutosave _autosave =
      ref.read(scrollbackAutosaveFactoryProvider)(
        onTick: () {
          saveDirtyScrollback();
          return hasDirtyScrollback;
        },
      );

  final _log = AppLogger.named('terminal');

  /// Whether [shutdownProcesses] has already run.
  ///
  /// It empties [_tabs], so the container's own teardown must not persist
  /// afterwards: it would write that emptiness over the layout the user
  /// expects back.
  bool _processesShutDown = false;

  /// Set on teardown, so a post-frame callback that outlives the container
  /// cannot touch a disposed pane. See [_afterFrame].
  bool _disposed = false;

  /// How many [withOneLayoutSave] calls are in flight, and whether anything
  /// inside them has asked for a structural save. Counted rather than a flag so
  /// a bulk verb calling another still writes once, at the outermost end.
  int _heldLayoutSaves = 0;
  bool _layoutSaveOwed = false;

  @override
  TerminalSessionsState build() {
    ref.onDispose(() {
      _disposed = true;
      _autosave.stop();
      if (_processesShutDown) return;
      persistLayout();
      _disposeAll();
    });
    // A rename happens in the sessions feature and never touches a terminal, so
    // nothing here would republish and the tab strip would keep the old name.
    // `listen` rather than `watch`: re-running `build` would restore the
    // layout again.
    ref.listen(sessionsRevisionProvider, (_, _) {
      if (!_disposed) _publish();
    });
    _restoreLayout();
    // Once, here: a restore rebuilds the tab list from the store, and the tree
    // has to be in step with it before the first snapshot goes out.
    _reconcileWorkspace();
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
    persistLayout();
    await Future.wait(_disposeAll());
  }

  /// A projection of the controller's fields, and **nothing else**. Called from
  /// `build()` as well as from every publish, so anything with a side effect
  /// would be a write on a read path — see [_publish].
  TerminalSessionsState _snapshot() {
    return TerminalSessionsState(
      tabs: _tabsView ??= List.unmodifiable(_tabs),
      activeTabId: _activeTabId,
      workspace: _workspace,
      focusedGroupId: _focusedGroupId,
      detached: _detachedView ??= List.unmodifiable(_detached),
      liveness: _livenessView ??= Map.unmodifiable({
        for (final entry in _instances.entries)
          entry.key: entry.value.liveness.value,
      }),
      workingDirectories: _directoriesView ??= Map.unmodifiable({
        for (final entry in _instances.entries)
          entry.key: entry.value.workingDirectory,
      }),
      titleRevision: _titleRevision,
    );
  }

  void _publish() {
    _warnIfPublishingDuringBuild();
    // Every tab verb ends at the tab list, and the group tree is brought back
    // in step with it here — on the way *out*, in a write, rather than inside
    // [_snapshot], which `build()` also calls. A reconciler reachable from a
    // read is one that can write at a moment the framework cannot let anybody
    // see, which Riverpod refuses in debug and swallows in release.
    _reconcileWorkspace();
    _titleRevision++;
    _titles.clear();
    _applyIngestTiers();
    state = _snapshot();
  }

  /// Says **where** a publish landed inside a build, in debug only.
  ///
  /// Riverpod's own "tried to modify a provider while the widget tree was
  /// building" names no location, which makes it a bug that has to be hunted
  /// rather than read. This controller is the busiest writer in the app, so it
  /// carries the sign: inside an `assert`, so a release build pays nothing.
  void _warnIfPublishingDuringBuild() {
    assert(() {
      // The controller is deliberately usable without a widget tree — most of
      // its own tests drive it that way — and asking for the binding there
      // throws rather than answering.
      final binding = _bindingOrNull();
      if (binding?.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        _log.warning(
          'The terminal published while the widget tree was building. '
          'Riverpod cannot promise anybody sees this, so the layout may go '
          'stale. The stack below is the write.',
          null,
          StackTrace.current,
        );
      }
      return true;
    }());
  }

  /// Notifies title providers that an underlying session title changed.
  void notifyTitleChanged() {
    _warnIfPublishingDuringBuild();
    _titleRevision++;
    _titles.clear();
    state = _snapshot();
  }

  /// Drops the projections and indexes derived from [_tabs].
  ///
  /// Called at every one of the seven places the tab list changes shape. It is
  /// deliberately one method rather than incremental maintenance: an index that
  /// is rebuilt wholesale cannot drift, and the rebuild is O(tabs) on a
  /// structural change rather than on every publish.
  void _tabsMutated() {
    _tabsView = null;
    _tabIndexById = null;
    _tabIdByPane = null;
  }

  void _detachedMutated() => _detachedView = null;

  /// Drops the liveness projection — a pane was adopted, released, or its
  /// process changed state.
  void _livenessMutated() => _livenessView = null;

  /// Drops the directory projection — a pane was adopted, released, or its
  /// shell said it moved. Exactly as narrow as [_livenessMutated]: a `cd`
  /// leaves the tab list, the detached list and every pane's liveness alone.
  void _directoriesMutated() => _directoriesView = null;

  Map<String, int> get _tabIndex =>
      _tabIndexById ??= {for (var i = 0; i < _tabs.length; i++) _tabs[i].id: i};

  Map<String, String> get _paneOwner => _tabIdByPane ??= {
    for (final tab in _tabs)
      for (final paneId in tab.layout.panes) paneId: tab.id,
  };

  /// Tells every pane how visible it is, so ingestion can cost what the pane is
  /// worth rather than the same for all of them.
  ///
  /// The layout is the only thing that knows this, which is why it lives
  /// here and not in the pane: a pane cannot see which tab is in front. Called
  /// from [_publish], so every open, close, split, activate, detach and
  /// reattach re-derives it from one place — there is no second path that could
  /// leave a pane at the wrong tier.
  ///
  /// * **hot** — every pane the active tab is actually *showing*: the front
  ///   pane of each of its regions, focused or not. A pane stacked behind
  ///   another in a region is not on screen, however close to the front it is.
  /// * **warm** — panes of every other open tab, and the ones stacked out of
  ///   sight in this one. Correct, but not watched.
  /// * **cold** — anything still tracked with no tab at all, which is a
  ///   detached session. Not parsed; its output spools.
  ///
  /// Cost is O(panes) per publish plus one set of the regions on screen, and
  /// every pane whose tier did not change returns immediately, which is nearly
  /// all of them nearly always.
  void _applyIngestTiers() {
    final owner = _paneOwner;
    final onScreen = _activeTab?.layout.visiblePanes.toSet() ?? const <String>{};
    for (final entry in _instances.entries) {
      if (entry.value case final TieredTerminalInstance tiered) {
        final tabId = owner[entry.key];
        tiered.setIngestTier(
          tabId == null
              ? IngestTier.cold
              : tabId == _activeTabId && onScreen.contains(entry.key)
              ? IngestTier.hot
              : IngestTier.warm,
        );
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
    _directoryListeners.clear();
    _dirty.clear();
    _dirtySince.clear();
    _encoded.clear();
    _tabs.clear();
    _detached.clear();
    _activeTabId = null;
    _workspace = null;
    _focusedGroupId = null;
    _tabsMutated();
    _detachedMutated();
    _livenessMutated();
    _directoriesMutated();
    return reaping;
  }

  /// The live terminal behind [paneId], or `null` once it has been closed.
  TerminalInstance? instanceFor(String paneId) => _instances[paneId];

  /// Recreates the stored layout: the tabs, the splits inside them, and each
  /// pane's scrollback — as a **dormant** buffer, except for the panes of the
  /// active tab that were running when the app closed, which get a process back.
  ///
  /// The owner, twice: *"why when app restart the active pane doesn't
  /// automatically resume the session? why must i tap start again"*, and then
  /// *"if there were active panes on last close start all those panes on active
  /// tab"*. `shouldRestartOnLaunch` holds the whole of which panes those are and
  /// why the others are still records; the ones it refuses come back exactly as
  /// they always did, marked restored with an explicit Start.
  ///
  /// A restarted pane is built **here**, in place of the dormant one, rather
  /// than started afterwards through [startPane]. Three things follow from that
  /// and all three are the point: nothing publishes state during `build` (which
  /// Riverpod forbids), the first frame already shows a live terminal instead of
  /// a "Session ended" bar that vanishes, and the stored scrollback is parsed
  /// once — where starting afterwards would build the dormant pane's buffer and
  /// then throw it away.
  ///
  /// Defensive at every step: a layout that will not parse, a pane whose profile
  /// no longer exists, a tab left with nothing in it — each is dropped rather
  /// than thrown on, because a corrupt row must never make the terminal
  /// unopenable. The worst case is an empty layout, which is what a first run
  /// looks like anyway.
  void _restoreLayout() {
    // Whatever the previous life of this controller decided about closing
    // things, this one starts owing the store the layout it just read.
    _userClosedSinceRestore = false;
    final dao = _dao();
    if (dao == null) return;

    try {
      _gridHint.grid = dao.loadPaneGrid();
      _writtenGrid = _gridHint.grid;
      final stored = dao.loadLayout();
      // Which tab counts as "the active tab" has to be decided before any pane
      // is built, and the same way the fallback below decides it: a layout
      // stored with no active row activates its last tab. Resolved against the
      // *stored* list rather than the rebuilt one, so a last tab that turns out
      // to be unrebuildable starts nothing rather than promoting another tab's
      // panes into a decision the user never made.
      final activeTabId =
          stored.activeTabId ??
          (stored.tabs.isEmpty ? null : stored.tabs.last.id);
      for (final storedTab in stored.tabs) {
        final rebuilt = <String>{};
        for (final pane in storedTab.panes) {
          if (!storedTab.layout.contains(pane.id)) continue;
          if (_adoptRestored(pane, inActiveTab: storedTab.id == activeTabId)) {
            rebuilt.add(pane.id);
          }
        }

        final layout = storedTab.layout.withoutMissing(rebuilt);
        if (layout == null) continue;
        final stayed = storedTab.focusedPaneId;
        final kept = stayed != null && layout.contains(stayed);
        _tabs.add(
          TerminalTab(
            id: storedTab.id,
            // `activate` restates the invariant rather than trusting it: the
            // stored front pane of a region may be one of the panes that could
            // not be rebuilt, and the focused pane has to be the one on screen.
            layout: kept ? layout.activate(stayed) : layout,
            focusedPaneId: kept ? stayed : layout.visiblePanes.first,
          ),
        );
        _tabsMutated();
        if (storedTab.id == stored.activeTabId) _activeTabId = storedTab.id;
      }

      // Sessions that had no tab last time stay tab-less: they come back in the
      // background list, where the user reopens the ones still worth having.
      // They are in no tab, so they are never in the *active* one, and a
      // detached session is precisely the thing the user already closed the
      // view of — starting one would spawn a process with nowhere to show it.
      for (final storedTab in stored.detached) {
        for (final pane in storedTab.panes) {
          if (!_adoptRestored(pane, inActiveTab: false)) continue;
          _detached.add(
            DetachedSession(
              paneId: pane.id,
              title: pane.title,
              workingDirectory: pane.workingDirectory,
              detachedAt: ref.read(clockProvider).nowUtc(),
            ),
          );
          _detachedMutated();
        }
      }

      _activeTabId ??= _tabs.isEmpty ? null : _tabs.last.id;
      _restoreWorkspace(dao.loadWorkspace());
    } catch (error, stack) {
      _log.warning('Could not restore the terminal layout.', error, stack);
    }
  }

  /// Puts the tabs that came back into the groups they were in.
  ///
  /// Pruned against the tabs that actually rebuilt, the same way a tab's own
  /// layout is: a group naming only tabs that could not be restored collapses,
  /// and a tab the tree never heard of joins the focused group when
  /// [_reconcileWorkspace] next runs. A tree that will not parse is no tree,
  /// which costs one group — what a first run has.
  void _restoreWorkspace(WorkspaceLayout? stored) {
    if (stored == null) return;
    final live = {for (final tab in _tabs) tab.id};
    final keep = {
      for (final id in stored.panes)
        if (live.contains(id) || isEmptyGroupSlot(id)) id,
    };
    if (keep.isEmpty) return;
    _workspace = stored.withoutMissing(keep);
    _writtenWorkspace = _workspace;
  }

  /// Rebuilds [pane]: with a process when it earned one, and as a process-free
  /// buffer holding its stored scrollback when it did not.
  ///
  /// Returns false when the pane's profile no longer resolves — a WSL distro
  /// that has been removed, say — since there would be nothing to start it with.
  bool _adoptRestored(StoredTerminalPane pane, {required bool inActiveTab}) {
    // An agent pane carries its own command, so it does not need — and never
    // had — a resolvable shell profile.
    final profile = terminalProfileFromId(pane.profileId);
    if (pane.agentLaunch == null && profile == null) return false;

    if (profile != null &&
        shouldRestartOnLaunch(
          enabled: _restoreLivePanes,
          wasLive: pane.wasLive,
          inActiveTab: inActiveTab,
          isAgentPane: pane.agentLaunch != null,
        ) &&
        _adoptRestarted(pane, profile)) {
      return true;
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
        // Remembered so opening this tab later can start what was running in
        // it — the launch rule only ever covers the tab left in front.
        wasLive: pane.wasLive,
        gridHint: _gridHint,
      ),
    );
    return true;
  }

  /// Gives [pane] a process again, replaying its stored scrollback above it.
  ///
  /// The same factory every other pane comes from, so a shell that will not
  /// spawn degrades exactly as it does anywhere else: to an
  /// [ErrorTerminalInstance] holding the reason above the history, reported as
  /// [PaneLiveness.exited] with a Restart on it. A pane that cannot start says
  /// so; it never comes back as a blank buffer pretending to be a shell.
  ///
  /// Returns false — and the caller falls back to the dormant pane — if the
  /// factory *throws* rather than degrading. Nothing in production does that,
  /// and this runs inside the restore: a layout must not be lost because one
  /// pane could not be started.
  bool _adoptRestarted(StoredTerminalPane pane, TerminalProfile profile) {
    final TerminalInstance instance;
    // Only the build is guarded, so a refusal is always a pane that was never
    // adopted — there is no half-adopted state for the dormant fallback to be
    // laid over.
    try {
      instance = ref.read(terminalInstanceFactoryProvider)(
        id: pane.id,
        profile: profile,
        workingDirectory: pane.workingDirectory,
        restoredScrollback: pane.scrollback,
        shellIntegration: _shellIntegrationEnabled,
      );
    } catch (error, stack) {
      _log.warning(
        'Could not restart pane ${pane.id} on launch; it comes back as '
        'restored history instead.',
        error,
        stack,
      );
      return false;
    }
    _adopt(pane.id, instance);
    // The buffer this pane came back with *is* the stored scrollback, replayed.
    // Without seeding, the first structural save of the run — the one that
    // follows the user's first click — encodes every restarted pane in full to
    // learn what the store already read out to it. See [_seedEncoding].
    _seedEncoding(pane.id, pane.scrollback);
    return true;
  }

  /// The layout DAO, or `null` when no database is wired up.
  TerminalLayoutDao? _dao() {
    try {
      return ref.read(terminalLayoutDaoProvider);
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

  /// Read at restore time rather than watched, for the same reason: this
  /// decides what a *launch* does, and toggling it must never reach into panes
  /// that are already open.
  bool get _restoreLivePanes => ref.read(restoreLivePanesProvider);

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
      // Never out of somewhere the keyboard is already spoken for — a text
      // field the user is typing in, or a device mirror that is forwarding
      // every keystroke to a phone. Opening or closing a terminal tab is not
      // worth taking the keyboard away from either of them.
      if (keyboardIsSpokenFor()) return;
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

}

/// Whether [title] is a pane reciting the program we launched rather than
/// saying anything about the work going on in it.
///
/// ConPTY hands the child's image path through as a pane's window title, so a
/// WSL pane opens announcing itself as `C:\Windows\System32\wsl.exe` — the
/// wrapper this app put in front of the shell, and the one thing about the pane
/// the user already knows.
///
/// Two conditions, and it takes both to stay narrow. The title has to be an
/// absolute path *and nothing else*, which leaves `user@host: /home/me/src` and
/// a bare `wsl` alone — those are real titles a real shell sends. And the file
/// it names has to be [launcher] itself, so a pane naming some other path is
/// still believed. Compared case-insensitively, because the path comes from
/// Windows and its casing is not ours to predict.
/// An image name inside a command line — `wsl.exe`, `C:\\…\\powershell.exe`.
/// Quotes and whitespace end a token, which is what keeps a quoted path with a
/// space in it from swallowing the flag after it.
final RegExp _executableToken = RegExp(r'[^\s"]+\.exe', caseSensitive: false);

bool _namesLauncher(String title, Set<String> launchers) {
  if (launchers.isEmpty || !_isAbsolutePath(title)) return false;
  return launchers.contains(_basename(title).toLowerCase());
}

/// Whether [path] is rooted — a drive (`C:\…`), a UNC share (`\\…`) or POSIX
/// (`/…`).
bool _isAbsolutePath(String path) {
  if (path.startsWith('/') || path.startsWith('\\')) return true;
  if (path.length < 3 || path[1] != ':') return false;
  if (path[2] != '\\' && path[2] != '/') return false;
  final drive = path.codeUnitAt(0) | 0x20;
  return drive >= 0x61 && drive <= 0x7a;
}

/// The last segment of [path], for either separator — a Windows-first app has
/// both, often in the same pane.
String _basename(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  final at = slash > backslash ? slash : backslash;
  return at < 0 ? path : path.substring(at + 1);
}
