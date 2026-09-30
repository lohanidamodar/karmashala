import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:xterm2/xterm.dart';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../../core/capabilities/capabilities.dart'
    show clientCapabilitiesProvider;
import '../../../core/data/data_providers.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../editor/domain/document_id.dart';
import '../../environments/application/environments_controller.dart';
import '../../notes/application/notes_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/launch.dart';
import 'package:karmashala_terminal_runtime/scrollback.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'local_host_providers.dart';
import '../data/terminals_client.dart';
import '../../sessions/data/sessions_client.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        TerminalOpen,
        TerminalRecord,
        hostedRunSessionId,
        terminalSessionId;
import 'package:karmashala_host_protocol/protocol.dart' show boxSessionRef;
import 'package:karmashala_environments/ssh.dart' show sshEnvironmentId;
import 'terminal_layout_providers.dart';
import 'pane_exit_signal.dart';
import 'scrollback_autosave.dart';
import 'terminal_profiles.dart';
import 'browser_document_pane.dart';

// `part`s rather than libraries because privacy in Dart is per library: every
// verb below writes the fields declared here.
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
part 'terminal_sessions_restore.dart';

/// Manages open terminal tabs, the split tree in each, focus, and persisting
/// the layout. Tabs are **fields**, not [state] — `build`/`onDispose` need them.
class TerminalSessionsController extends Notifier<TerminalSessionsState> {
  final List<TerminalTab> _tabs = [];
  String? _activeTabId;

  /// Tab ids most-recently-active first. Closing a tab hands the keyboard back
  /// to where the user was *before* it, rather than to whichever tab happens
  /// to sit first in the strip.
  final List<String> _tabOrder = [];

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

  /// Panes being **ended**, not closed: their hosted session is ended on the
  /// host before the link is dropped. A release that is not in here is a
  /// disconnect, and the host keeps the session for the next pane.
  final Set<String> _ending = {};

  /// Sessions with a running process and no tab, oldest first.
  final List<DetachedSession> _detached = [];

  /// Published projections, each nulled only by the thing it derives from — so
  /// a publish that moved one pane's liveness hands back the *same* tab list.
  List<TerminalTab>? _tabsView;
  List<DetachedSession>? _detachedView;
  Map<String, PaneLiveness>? _livenessView;
  Map<String, String?>? _directoriesView;
  Map<String, int>? _tabIndexById;
  Map<String, String>? _tabIdByPane;

  /// Panes whose buffer changed since their last snapshot.
  final Set<String> _dirty = {};

  /// When each dirty pane *became* dirty. Written only on the clean→dirty
  /// transition: `markDirty` runs on every notification of every pane, so a
  /// clock read there would be a per-frame per-pane cost.
  final Map<String, Duration> _dirtySince = {};

  /// Monotonic, so an unsaved age cannot be distorted by the wall clock moving.
  final Stopwatch _uptime = Stopwatch()..start();

  /// What the last completed scrollback write cost and covered. Null until one
  /// has run — reported as "not recorded" rather than as zero.
  ScrollbackWrite? _lastWrite;

  /// How wide the workbench draws a pane, shared so a restored pane does not
  /// parse its history at xterm's default 80 columns and get reflowed. Seeded
  /// from the store: restore parses history in `build`, before any layout pass.
  final TerminalGridHint _gridHint = TerminalGridHint();

  /// The grid last written to the store, so a save that would write the same
  /// value writes nothing.
  ({int columns, int rows})? _writtenGrid;

  /// The last encoding written for each pane. A pane not in [_dirty] can only
  /// re-encode to the same string, which is what makes a save on every
  /// structural change — and the save on quit — affordable.
  final Map<String, String> _encoded = {};

  /// Per-pane buffer listeners, kept so they can be removed on close.
  final Map<String, void Function()> _dirtyListeners = {};

  /// Per-pane liveness listeners, kept for the same reason.
  final Map<String, void Function()> _livenessListeners = {};

  /// Per-pane working-directory listeners, kept for the same reason.
  final Map<String, void Function()> _directoryListeners = {};

  /// Titles panes set for themselves with OSC 0/2. Outranks the directory, but
  /// not an agent pane's own name ([_titleForPane]); a title merely reciting
  /// the launcher is filtered on the way *in* ([_namesLauncher]).
  final Map<String, String> _oscTitles = {};

  /// Resolved tab labels, cleared on every publish. A label can cost a database
  /// read, and the tab strip asks for one per tab per build.
  final Map<String, String> _titles = {};

  /// Monotonically increasing revision number incremented on every publish.
  int _titleRevision = 0;

  /// Whether the user closed a tab, pane or session since the restore — the only
  /// licence to write an empty layout. A pane exiting on its own does not set it.
  bool _userClosedSinceRestore = false;

  late final ScrollbackAutosave _autosave =
      ref.read(scrollbackAutosaveFactoryProvider)(
        onTick: () {
          saveDirtyScrollback();
          return hasDirtyScrollback;
        },
      );

  final _log = AppLogger.named('terminal');

  /// Whether [shutdownProcesses] has run. It empties [_tabs], so the
  /// container's teardown must not then persist that emptiness.
  bool _processesShutDown = false;

  /// Set on teardown, so a post-frame callback that outlives the container
  /// cannot touch a disposed pane. See [_afterFrame].
  bool _disposed = false;

  /// Counted rather than a flag, so a bulk verb calling another still writes
  /// once, at the outermost end.
  int _heldLayoutSaves = 0;
  bool _layoutSaveOwed = false;

  @override
  TerminalSessionsState build() {
    ref.onDispose(() {
      _disposed = true;
      _autosave.stop();
      if (_processesShutDown) return;
      persistLayout();
      // `forExit` here too: this provider is not auto-disposed, so the only way
      // in is the container going away as the process ends — and
      // [shutdownProcesses] can be skipped when the budget is already spent.
      _disposeAll(forExit: true);
    });
    // A rename never touches a terminal, so nothing here would republish and
    // the strip would keep the old name. `listen`, not `watch`: re-running
    // `build` would restore the layout again.
    ref.listen(sessionsRevisionProvider, (_, _) {
      if (!_disposed) _publish();
    });
    _restoreLayout();
    // The tree has to be in step with the restored tab list before the first
    // snapshot goes out.
    _reconcileWorkspace();
    // After the snapshot, never inside `build`: asking the host is a socket
    // round-trip, and a pane that reattaches publishes.
    unawaited(_hostSurvivors = _reattachHostSurvivors());
    // A client that cannot run the server keeps no scrollback of its own: the
    // server holds it, and a reattach replays it.
    if (ref.read(clientCapabilitiesProvider).hostsServer) _autosave.start();
    return _snapshot();
  }

  Future<void> _hostSurvivors = Future.value();

  /// Completes once this run has asked the session host what survived and
  /// reattached it — an event a test can wait on instead of a sleep.
  @visibleForTesting
  Future<void> get hostSurvivorsReattached => _hostSurvivors;

  /// Ends every pane's process and awaits the kills: `ref.onDispose` is
  /// synchronous, so `taskkill` was still in flight when the process ended.
  Future<void> shutdownProcesses() async {
    if (_processesShutDown) return;
    _processesShutDown = true;
    _autosave.stop();
    persistLayout();
    // Counted at both ends: this step spends most of the shutdown budget, and
    // one pane reaching the cap and eleven reaching it are different findings.
    final reaping = _disposeAll(forExit: true);
    _log.info('terminal: reaping ${reaping.length} pane process tree(s).');
    await Future.wait(reaping);
    _log.info('terminal: ${reaping.length} pane process tree(s) reaped.');
  }

  /// A projection of the controller's fields and **nothing else**: `build()`
  /// calls it too, so a side effect here would be a write on a read path.
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
    _rememberActiveTab();
    // Here, on the way out, rather than in [_snapshot], which `build()` also
    // calls: a reconciler reachable from a read writes at a moment Riverpod
    // refuses in debug and swallows in release.
    _reconcileWorkspace();
    _titleRevision++;
    _titles.clear();
    _applyIngestTiers();
    state = _snapshot();
  }

  /// Records the tab on screen as the most recent, and forgets tabs that have
  /// gone. Done on the way out of every mutation, so no tab verb has to
  /// remember to.
  void _rememberActiveTab() {
    final id = _activeTabId;
    if (id != null && (_tabOrder.isEmpty || _tabOrder.first != id)) {
      _tabOrder
        ..remove(id)
        ..insert(0, id);
    }
    _tabOrder.removeWhere((tabId) => !_tabIndex.containsKey(tabId));
  }

  /// The most recently active tab that survives [closing] and is in the group
  /// the user is working in. Null when none of them is.
  String? _mostRecentSurvivor(Set<String> closing) {
    final group = _focusedGroup;
    for (final id in _tabOrder) {
      if (closing.contains(id) || _tabById(id) == null) continue;
      if (group != null && !group.panes.contains(id)) continue;
      return id;
    }
    return null;
  }

  /// Says **where** a publish landed inside a build, in debug only: Riverpod's
  /// own "tried to modify a provider while the widget tree was building" names
  /// no location. Inside an `assert`, so a release build pays nothing.
  void _warnIfPublishingDuringBuild() {
    assert(() {
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

  /// Drops everything derived from [_tabs]. Wholesale rather than incremental:
  /// an index rebuilt from scratch cannot drift, and it costs O(tabs) on a
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

  /// Drops the directory projection. As narrow as [_livenessMutated]: a `cd`
  /// leaves the tab list, the detached list and every pane's liveness alone.
  void _directoriesMutated() => _directoriesView = null;

  Map<String, int> get _tabIndex =>
      _tabIndexById ??= {for (var i = 0; i < _tabs.length; i++) _tabs[i].id: i};

  Map<String, String> get _paneOwner => _tabIdByPane ??= {
    for (final tab in _tabs)
      for (final paneId in tab.layout.panes) paneId: tab.id,
  };

  /// Tells every pane how visible it is — hot, warm, cold. Here because a pane
  /// cannot see which tab is in front, and from [_publish] so no path skips it.
  void _applyIngestTiers() {
    final owner = _paneOwner;
    final onScreen =
        _activeTab?.layout.visiblePanes.toSet() ?? const <String>{};
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

  /// Disposes every pane, returning the links still closing. No pane owns a
  /// process since slice 5a: disposing one disconnects it, and its terminal
  /// keeps running at the server.
  List<Future<void>> _disposeAll({bool forExit = false}) {
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

  /// A pane of this window whose agent is session [sessionId] and is [where],
  /// or `null`. The session's row names only the pane that last opened it, and
  /// every window writes its own there — a phone opening the session left the
  /// desktop unable to find its tab, so each click attached another (owner,
  /// 2026-09-30).
  String? paneRunningSession(
    String sessionId,
    bool Function(PaneLiveness) where,
  ) {
    for (final MapEntry(key: paneId, value: instance) in _instances.entries) {
      if (instance.agentLaunch?.sessionId == sessionId &&
          where(instance.liveness.value)) {
        return paneId;
      }
    }
    return null;
  }

  /// What the panes are holding, for the memory census. O(panes), and every
  /// term is a length or a field read, so a pane with a megabyte of history
  /// costs what an empty one does.
  ///
  /// A pane whose buffer has never been built is counted in `unparsedPanes`
  /// and contributes no rows: reading a [DormantTerminalInstance]'s `terminal`
  /// *is* the scrollback parse the restore defers, so measuring it would be
  /// the cost it is measuring for.
  ({int live, int detached, int unparsedPanes, int rows, int heldChars})
  get paneFootprint {
    var unparsed = 0;
    var rows = 0;
    var chars = 0;
    for (final instance in _instances.values) {
      if (instance case final DormantTerminalInstance dormant) {
        // A restored pane keeps its stored history as text whether or not
        // anything has asked to see it — parsing it is what `bufferBuilt`
        // records, and doing so does not release the text.
        chars += dormant.restoredScrollback.length;
        if (dormant.bufferBuilt) {
          rows += _rowsHeldBy(dormant.terminal);
        } else {
          unparsed++;
        }
      } else {
        rows += _rowsHeldBy(instance.terminal);
      }
      if (instance case ParkableTerminalInstance(:final parkedScrollback)) {
        chars += parkedScrollback?.length ?? 0;
      }
    }
    for (final encoded in _encoded.values) {
      chars += encoded.length;
    }
    return (
      live: _instances.length,
      detached: _detached.length,
      unparsedPanes: unparsed,
      rows: rows,
      heldChars: chars,
    );
  }

  /// Every line a terminal is holding, both screens.
  ///
  /// **Not `terminal.buffer`.** That is the *active* buffer, and an agent TUI
  /// runs on the alternate screen — so reading it reports the alt screen's
  /// handful of rows and hides the main buffer's scrollback entirely, which is
  /// the part that grows. Measured while this was wrong: the census said 354
  /// rows against 6001 live `BufferLine`s, and 2800 against 8479.
  static int _rowsHeldBy(Terminal terminal) =>
      terminal.mainBuffer.lines.length + terminal.altBuffer.lines.length;

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

  /// Gives the active tab's focused pane the keyboard, a frame late:
  /// [IndexedStack] excludes focus from unselected children until the rebuild.
  void _focusActivePane() {
    // A thumb raises the keyboard by tapping the grid: focus given on show
    // put the keyboard over half the phone's screen to only look.
    if (ref.read(clientCapabilitiesProvider).density.isTouch) return;
    _afterFrame(() {
      final tab = _activeTab;
      if (tab == null) return;
      final node = _instances[tab.focusedPaneId]?.focusNode;
      if (node == null || node.hasFocus) return;
      // Never out of a text field being typed in, or a device mirror
      // forwarding keystrokes to a phone.
      if (keyboardIsSpokenFor()) return;
      node.requestFocus();
    });
  }

  /// Runs [action] once the pending rebuild has been laid out; a no-op with no
  /// binding. A post-frame callback, unlike a timer, does not trip
  /// `flutter_test`'s pending-work checks when no frame ever comes.
  void _afterFrame(void Function() action) {
    final binding = _bindingOrNull();
    if (binding == null) return;
    binding.addPostFrameCallback((_) {
      if (_disposed) return;
      action();
    });
  }

  /// The widget binding, or null. `WidgetsBinding.instance` throws rather than
  /// returning null, and the controller must work without a widget tree.
  static WidgetsBinding? _bindingOrNull() {
    try {
      return WidgetsBinding.instance;
    } catch (_) {
      return null;
    }
  }
}
