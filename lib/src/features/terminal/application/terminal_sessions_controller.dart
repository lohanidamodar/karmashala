import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_core/logging.dart';
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
import '../domain/document_pane.dart';
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

  /// Whether the user closed a tab, pane or session since the restore — the one
  /// thing the store cannot reconstruct, and so the only licence to write an
  /// empty layout over the user's tabs. A pane exiting on its own does not set
  /// it: a dead pane still has a row worth restoring.
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
    _autosave.start();
    return _snapshot();
  }

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
    // Here, on the way out, rather than in [_snapshot], which `build()` also
    // calls: a reconciler reachable from a read writes at a moment Riverpod
    // refuses in debug and swallows in release.
    _reconcileWorkspace();
    _titleRevision++;
    _titles.clear();
    _applyIngestTiers();
    state = _snapshot();
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

  /// Tells every pane how visible it is: hot for a pane the active tab is
  /// showing, warm for any other open tab's, cold for a detached session. Lives
  /// here because a pane cannot see which tab is in front, and runs from
  /// [_publish] so no second path can leave a pane at the wrong tier.
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

  /// Disposes every pane, returning the reaps still in flight. [forExit] means
  /// the process is ending, and its one effect is that a pane keeps its
  /// pseudoconsole for the OS to reclaim. See [PseudoConsoleOwner].
  List<Future<void>> _disposeAll({bool forExit = false}) {
    final reaping = <Future<void>>[];
    for (final entry in _instances.entries) {
      _unlisten(entry.key, entry.value);
      if (forExit && entry.value is PseudoConsoleOwner) {
        (entry.value as PseudoConsoleOwner).keepPseudoConsoleOnDispose();
      }
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

  /// Gives the active tab's focused pane the keyboard. Deferred a frame because
  /// [IndexedStack] wraps every unselected child in an `ExcludeFocus`, so until
  /// the rebuild that selects it `requestFocus()` is silently dropped. The pane
  /// is re-resolved in the callback, so a burst of switches lands on the last.
  void _focusActivePane() {
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
