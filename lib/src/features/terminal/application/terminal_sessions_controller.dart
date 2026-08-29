import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/id_generator_provider.dart';
import '../data/terminal_instance.dart';
import '../domain/pane_layout.dart';
import '../domain/terminal_profile.dart';

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

/// Manages open terminal tabs, the split tree inside each, and which pane has
/// focus.
///
/// Live instances are held here rather than in [state] so `onDispose` can tear
/// them down without reading state, which Riverpod forbids.
class TerminalSessionsController extends Notifier<TerminalSessionsState> {
  final Map<String, TerminalInstance> _instances = {};

  @override
  TerminalSessionsState build() {
    ref.onDispose(_disposeAll);
    return const TerminalSessionsState();
  }

  void _disposeAll() {
    for (final instance in _instances.values) {
      instance.dispose();
    }
    _instances.clear();
  }

  /// The live terminal behind [paneId], or `null` once it has been closed.
  TerminalInstance? instanceFor(String paneId) => _instances[paneId];

  /// Opens a new tab running [profile] and makes it active. Returns its id.
  String openTab(TerminalProfile profile, {String? workingDirectory}) {
    final tabId = _newId();
    final paneId = _createPane(profile, workingDirectory: workingDirectory);
    state = TerminalSessionsState(
      tabs: [
        ...state.tabs,
        TerminalTab(
          id: tabId,
          layout: PaneLayout.single(paneId),
          focusedPaneId: paneId,
        ),
      ],
      activeTabId: tabId,
    );
    return tabId;
  }

  void activateTab(String id) {
    if (state.activeTabId == id) return;
    state = TerminalSessionsState(tabs: state.tabs, activeTabId: id);
    _focusActivePane();
  }

  /// Closes tab [id], disposing every pane in it.
  void closeTab(String id) {
    final tab = _tabById(id);
    if (tab == null) return;
    for (final paneId in tab.layout.panes) {
      _instances.remove(paneId)?.dispose();
    }

    final tabs = [for (final t in state.tabs) if (t.id != id) t];
    var activeTabId = state.activeTabId;
    if (activeTabId == id) {
      activeTabId = tabs.isEmpty ? null : tabs.last.id;
    }
    state = TerminalSessionsState(tabs: tabs, activeTabId: activeTabId);
  }

  /// Splits the active tab's focused pane along [axis], running [profile] in the
  /// new pane and focusing it. Returns the new pane id, or `null` if no tab is
  /// open.
  String? splitPane(
    SplitAxis axis,
    TerminalProfile profile, {
    String? workingDirectory,
  }) {
    final tab = state.activeTab;
    if (tab == null) return null;

    final paneId = _createPane(profile, workingDirectory: workingDirectory);
    final layout = tab.layout.split(tab.focusedPaneId, axis, paneId, _newId());
    _replaceTab(tab.copyWith(layout: layout, focusedPaneId: paneId));
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

    _instances.remove(paneId)?.dispose();
    final focused = layout.contains(tab.focusedPaneId)
        ? tab.focusedPaneId
        : layout.panes.first;
    _replaceTab(tab.copyWith(layout: layout, focusedPaneId: focused));
    _focusActivePane();
  }

  /// Focuses [paneId], activating the tab that holds it.
  void focusPane(String paneId) {
    final tab = _tabContaining(paneId);
    if (tab == null) return;
    state = TerminalSessionsState(
      tabs: [
        for (final t in state.tabs)
          if (t.id == tab.id) t.copyWith(focusedPaneId: paneId) else t,
      ],
      activeTabId: tab.id,
    );
    _instances[paneId]?.focusNode.requestFocus();
  }

  /// Moves focus to the pane adjacent to the focused one in [direction].
  void movePaneFocus(PaneDirection direction) {
    final tab = state.activeTab;
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

  // --- internals -------------------------------------------------------------

  String _newId() => ref.read(idGeneratorProvider).newId();

  String _createPane(
    TerminalProfile profile, {
    String? workingDirectory,
    String? restoredScrollback,
  }) {
    final paneId = _newId();
    final factory = ref.read(terminalInstanceFactoryProvider);
    _instances[paneId] = factory(
      id: paneId,
      profile: profile,
      workingDirectory: workingDirectory,
      restoredScrollback: restoredScrollback,
    );
    return paneId;
  }

  TerminalTab? _tabById(String id) {
    for (final tab in state.tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  TerminalTab? _tabContaining(String paneId) {
    for (final tab in state.tabs) {
      if (tab.layout.contains(paneId)) return tab;
    }
    return null;
  }

  void _replaceTab(TerminalTab updated) {
    state = TerminalSessionsState(
      tabs: [
        for (final tab in state.tabs)
          if (tab.id == updated.id) updated else tab,
      ],
      activeTabId: state.activeTabId,
    );
  }

  void _stepTab(int by) {
    if (state.tabs.length < 2) return;
    final index = state.tabs.indexWhere((t) => t.id == state.activeTabId);
    if (index < 0) return;
    final next = (index + by + state.tabs.length) % state.tabs.length;
    activateTab(state.tabs[next].id);
  }

  void _focusActivePane() {
    final tab = state.activeTab;
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
