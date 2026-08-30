import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../settings/application/settings_controller.dart';
import '../data/scrollback_codec.dart';
import '../data/terminal_instance.dart';
import '../data/terminal_workspace_dao.dart';
import '../domain/agent_pane_launch.dart';
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

  /// Per-pane buffer listeners, kept so they can be removed on close.
  final Map<String, void Function()> _dirtyListeners = {};

  /// Per-pane liveness listeners, kept for the same reason.
  final Map<String, void Function()> _livenessListeners = {};

  late final ScrollbackAutosave _autosave = ref.read(
    scrollbackAutosaveFactoryProvider,
  )(onTick: saveDirtyScrollback);

  final _log = AppLogger.named('terminal');

  @override
  TerminalSessionsState build() {
    ref.onDispose(() {
      _autosave.stop();
      persistWorkspace();
      _disposeAll();
    });
    _restoreWorkspace();
    _autosave.start();
    return _snapshot();
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

  void _publish() => state = _snapshot();

  void _disposeAll() {
    for (final entry in _instances.entries) {
      _unlisten(entry.key, entry.value);
      entry.value.dispose();
    }
    _instances.clear();
    _dirtyListeners.clear();
    _livenessListeners.clear();
    _dirty.clear();
    _tabs.clear();
    _detached.clear();
    _activeTabId = null;
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
    _instances[paneId]?.focusNode.requestFocus();
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
    _instances[paneId]?.focusNode.requestFocus();
  }

  // --- persistence -----------------------------------------------------------

  /// Writes the whole workspace — tabs, layouts, detached sessions and every
  /// pane's scrollback.
  ///
  /// Runs on every structural change (open, split, close, detach, end, start)
  /// and on teardown, because on Windows "quit" means `windowManager.destroy()`
  /// and the provider container is never disposed: anything not written by the
  /// time the user quits is simply gone. The 20 s autosave covers scrollback
  /// between those points.
  ///
  /// Does nothing when no database is wired up (tests, and any bootstrap that
  /// has not opened one).
  void persistWorkspace() {
    final dao = _dao();
    if (dao == null) return;
    try {
      dao.saveWorkspace([
        for (final tab in _tabs) _storedTab(tab),
        for (final session in _detached) ?_storedDetached(session),
      ], activeTabId: _activeTabId);
      _dirty.clear();
    } catch (error, stack) {
      _log.warning('Could not persist the terminal workspace.', error, stack);
    }
  }

  /// Re-encodes only the panes whose buffers changed, returning the pane ids
  /// written. This is the autosave tick.
  List<String> saveDirtyScrollback() {
    final dao = _dao();
    if (dao == null || _dirty.isEmpty) return const [];

    final written = <String>[];
    try {
      for (final paneId in _dirty.toList()) {
        final instance = _instances[paneId];
        if (instance == null) continue;
        dao.saveScrollback(paneId, encodeScrollback(instance.terminal));
        written.add(paneId);
      }
      _dirty.clear();
    } catch (error, stack) {
      _log.warning('Could not autosave terminal scrollback.', error, stack);
    }
    return written;
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
              scrollback: encodeScrollback(instance.terminal),
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
          scrollback: encodeScrollback(instance.terminal),
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

  void _focusActivePane() {
    final tab = _activeTab;
    if (tab == null) return;
    _instances[tab.focusedPaneId]?.focusNode.requestFocus();
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
