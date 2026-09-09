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
    _detachedMutated();

    final tabId = _newTabFor(paneId);
    _publish();
    persistStructure();
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
    _detachedMutated();
    _releasePane(paneId);
    _publish();
    persistStructure();
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
    _detachedMutated();
    _publish();
    persistStructure();
  }

  /// Every pane in a tab holding **restored agent history**: a session that was
  /// open when the app was last closed, rebuilt from disk with nothing running
  /// behind it.
  ///
  /// What "resume all" acts on, and what the toolbar counts. In tab order and
  /// then in each tab's own pane order, so a bulk resume walks them the way the
  /// user laid them out rather than the way a hash map happens to.
  ///
  /// **Detached panes are deliberately absent.** A session with no tab belongs
  /// to the background list and is reopened from [BackgroundSessionsDialog];
  /// counting it here as well would put one session in two dialogs, each
  /// offering a different verb for it.
  ///
  /// Shell panes are absent for the reason `shouldResumeRatherThanRestart`
  /// gives: there is no conversation to continue in one, and its Start button
  /// already does the right thing on its own.
  List<String> restoredAgentPanes() => [
    for (final tab in _tabs)
      for (final paneId in tab.layout.panes)
        if (_isRestoredAgentPane(paneId)) paneId,
  ];

  bool _isRestoredAgentPane(String paneId) {
    final instance = _instances[paneId];
    return instance != null &&
        instance.agentLaunch != null &&
        instance.liveness.value == PaneLiveness.restored;
  }

  /// Starts a process in [paneId], replaying whatever is already in its buffer
  /// above the new one.
  ///
  /// This is the only way a pane the launch declined to restart gets a process
  /// — an agent pane, a background tab, a pane whose process had already
  /// exited, or any pane at all when the setting is off — so restarting the app
  /// can still never re-execute a build or an agent behind the user's back.
  /// Also the retry path for a pane whose process exited or failed to spawn.
  ///
  /// What a launch *does* start, and why those cases are different, is
  /// `shouldRestartOnLaunch`; it builds the pane live rather than coming
  /// through here.
  ///
  /// Does nothing for a pane that is already live.
  void startPane(String paneId) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return;
    // An agent pane is restarted from its recorded command, not from a shell
    // profile: `agent:<id>` deliberately does not resolve as one. What it is
    // *not* restarted with is the MCP flags of the run that recorded it — see
    // [_liveMcpArgumentsFor].
    final recorded = existing.agentLaunch;
    final agentLaunch = recorded?.withMcpArguments(
      _liveMcpArgumentsFor(recorded),
    );
    final profile = agentLaunch != null
        ? TerminalProfile.powerShell
        : terminalProfileFromId(existing.profileId);
    if (profile == null) return;

    // The buffer this pane is already holding, when it has one worth taking:
    // the history is then handed over rather than encoded out and parsed back
    // in. Otherwise a dormant pane hands back exactly what was restored and a
    // parked one the window it kept; a pane whose buffer we can neither adopt
    // nor read as text has to be re-encoded.
    final adopt = _adoptableBufferOf(existing);
    final scrollback = adopt != null
        ? null
        : _heldScrollbackOf(existing) ?? encodeScrollback(existing.terminal);
    final workingDirectory = existing.workingDirectory;
    // Taken before the release, which drops it: this is the history the new
    // pane starts from, and handing it on is what stops the save below
    // encoding it back out again. See [_seedEncoding].
    final carried = scrollback ?? _encoded[paneId] ?? _heldScrollbackOf(existing);

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
        adoptTerminal: adopt,
      ),
    );
    _seedEncoding(paneId, carried);
    _publish();
    persistStructure();
    _focusActivePane();
  }

  /// The MCP flags a pane started **now** should carry, which are never the
  /// ones it was started with before.
  ///
  /// Every value in those flags belongs to one run of the app: the config
  /// directory is deleted on the way in, the control server binds whatever port
  /// it can get, and the URL's last segment is a credential minted for this
  /// process. A restored pane used to replay all three, and the agent refused
  /// to start at all:
  ///
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: `…/karmashala/mcp/session-<uuid>.json`
  ///
  /// An empty answer is the ordinary one — no server, no session row, a
  /// terminal-only container — and it is the right one: a pane without its
  /// tools is a smaller loss than a pane that will not open, which is the trade
  /// `SessionLauncher` already makes at the original launch.
  List<String> _liveMcpArgumentsFor(AgentPaneLaunch launch) {
    try {
      return ref.read(agentPaneMcpArgumentsProvider)(launch);
    } catch (_) {
      return const [];
    }
  }

  /// Runs [launch] in the pane [paneId] already has, keeping everything in its
  /// buffer, and brings that pane back on screen. Returns the tab it is now in,
  /// or `null` when there is no such pane or something is still running in it.
  ///
  /// The counterpart to [openAgentTab] for a session that already has a pane —
  /// which, after a restart, every restored session does. That pane is the
  /// session's own record of itself and the reason its scrollback was kept, so
  /// resuming *into* it is what leaves the user one terminal for one session
  /// rather than a dormant pane and a live one side by side.
  ///
  /// Unlike [startPane] the command is the caller's, not the pane's: a resume
  /// is a different command line from the launch that was recorded, and
  /// re-running the recorded one would start a new conversation instead of
  /// continuing the stored one.
  ///
  /// Refusing a live pane is the same rule [startPane] applies, and for the
  /// same reason: the caller wants a process for this session, and taking one
  /// that is already running away from it is not that.
  String? startAgentInPane(String paneId, AgentPaneLaunch launch) {
    final existing = _instances[paneId];
    if (existing == null || existing.liveness.value.isLive) return null;

    // Asked for before the pane is released, and through the same helpers
    // [startPane] uses: the buffer is handed over when the pane has one, and a
    // dormant pane that has never been looked at hands back exactly what was
    // restored without ever building the buffer the restore did not build.
    final adopt = _adoptableBufferOf(existing);
    final scrollback = adopt != null
        ? null
        : _heldScrollbackOf(existing) ?? encodeScrollback(existing.terminal);
    // As in [startPane], and for the same reason: the history the resumed
    // pane starts from is history the store already holds.
    final carried = scrollback ?? _encoded[paneId] ?? _heldScrollbackOf(existing);
    _releasePane(paneId);
    _adopt(
      paneId,
      ref.read(terminalInstanceFactoryProvider)(
        id: paneId,
        // Unused for an agent pane, as in [openAgentTab].
        profile: TerminalProfile.powerShell,
        workingDirectory: launch.workingDirectory,
        restoredScrollback: scrollback,
        agentLaunch: launch,
        adoptTerminal: adopt,
      ),
    );
    _seedEncoding(paneId, carried);
    final tabId = _showPane(paneId);
    _publish();
    persistStructure();
    return tabId;
  }

  // --- persistence -----------------------------------------------------------

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

  /// The parsed buffer [instance] can hand to the pane that replaces it, if it
  /// has one.
  ///
  /// Asked **before** [_heldScrollbackOf], because a buffer that already exists
  /// is strictly cheaper than any text: taking it costs nothing, where the text
  /// costs a parse — and, for a pane whose process merely exited, an encode
  /// first. See [AdoptableTerminalInstance] for what declines.
  static Terminal? _adoptableBufferOf(TerminalInstance instance) =>
      switch (instance) {
        AdoptableTerminalInstance(:final adoptableBuffer) => adoptableBuffer,
        _ => null,
      };

  /// The scrollback [instance] is already holding as text, if it is.
  static String? _heldScrollbackOf(TerminalInstance instance) =>
      switch (instance) {
        DormantTerminalInstance(:final restoredScrollback) =>
          restoredScrollback,
        ParkableTerminalInstance(parkedScrollback: final parked?) => parked,
        _ => null,
      };

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
