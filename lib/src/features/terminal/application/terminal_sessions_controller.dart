import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../settings/application/settings_controller.dart';
import '../data/scrollback_codec.dart';
import '../data/terminal_instance.dart';
import '../data/terminal_workspace_dao.dart';
import '../domain/pane_layout.dart';
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

/// Open terminal tabs and which one is active.
class TerminalSessionsState {
  const TerminalSessionsState({this.tabs = const [], this.activeTabId});

  final List<TerminalTab> tabs;
  final String? activeTabId;

  bool get isEmpty => tabs.isEmpty;

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

  /// Panes whose buffer changed since their last snapshot.
  final Set<String> _dirty = {};

  /// Per-pane buffer listeners, kept so they can be removed on close.
  final Map<String, void Function()> _dirtyListeners = {};

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

  TerminalSessionsState _snapshot() =>
      TerminalSessionsState(tabs: List.of(_tabs), activeTabId: _activeTabId);

  void _publish() => state = _snapshot();

  void _disposeAll() {
    for (final entry in _instances.entries) {
      final listener = _dirtyListeners[entry.key];
      if (listener != null) entry.value.terminal.removeListener(listener);
      entry.value.dispose();
    }
    _instances.clear();
    _dirtyListeners.clear();
    _dirty.clear();
    _tabs.clear();
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
    return tabId;
  }

  void activateTab(String id) {
    if (_activeTabId == id) return;
    _activeTabId = id;
    _publish();
    _focusActivePane();
  }

  /// Closes tab [id], disposing every pane in it.
  void closeTab(String id) {
    final tab = _tabById(id);
    if (tab == null) return;
    for (final paneId in tab.layout.panes) {
      _releasePane(paneId);
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
    return paneId;
  }

  /// Closes [paneId], collapsing its split. Closes the tab if it was the last
  /// pane in it.
  void closePane(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null) return;

    final layout = tab.layout.close(paneId);
    if (layout == null) {
      closeTab(tab.id);
      return;
    }

    _releasePane(paneId);
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

  // --- persistence -----------------------------------------------------------

  /// Writes the whole workspace — tabs, layouts and every pane's scrollback.
  ///
  /// Runs on pane/tab close and on teardown. Does nothing when no database is
  /// wired up (tests, and any bootstrap that has not opened one).
  void persistWorkspace() {
    final dao = _dao();
    if (dao == null) return;
    try {
      dao.saveWorkspace([
        for (final tab in _tabs) _storedTab(tab),
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
            ),
      ],
    );
  }

  /// Recreates the stored workspace, spawning fresh shells with the previous
  /// session's scrollback replayed above them.
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
        final live = <String>{};
        for (final pane in storedTab.panes) {
          if (!storedTab.layout.contains(pane.id)) continue;
          final profile = terminalProfileFromId(pane.profileId);
          if (profile == null) continue;
          _adopt(
            pane.id,
            ref.read(terminalInstanceFactoryProvider)(
              id: pane.id,
              profile: profile,
              workingDirectory: pane.workingDirectory,
              restoredScrollback: pane.scrollback,
              shellIntegration: _shellIntegrationEnabled,
            ),
          );
          live.add(pane.id);
        }

        final layout = storedTab.layout.withoutMissing(live);
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
      _activeTabId ??= _tabs.isEmpty ? null : _tabs.last.id;
    } catch (error, stack) {
      _log.warning('Could not restore the terminal workspace.', error, stack);
    }
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
  }

  /// Disposes the pane [paneId] owns and stops tracking it.
  void _releasePane(String paneId) {
    final instance = _instances.remove(paneId);
    if (instance == null) return;
    final listener = _dirtyListeners.remove(paneId);
    if (listener != null) instance.terminal.removeListener(listener);
    _dirty.remove(paneId);
    instance.dispose();
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
