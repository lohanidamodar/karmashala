// A named layout, and nothing that is running in it.

import 'pane_layout.dart';

/// One pane's declaration inside a preset: what to start there, and where.
///
/// [id] is the pane id the preset's own [PresetTab.layout] refers to. It is not
/// a pane id in the app — opening a preset mints fresh ones — but the tree has
/// to name its leaves somehow, and keeping the captured ids makes a saved
/// preset readable next to the layout it came from.
class PresetPane {
  const PresetPane({
    required this.id,
    required this.profileId,
    this.workingDirectory,
  });

  final String id;
  final String profileId;
  final String? workingDirectory;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile': profileId,
    if (workingDirectory != null) 'cwd': workingDirectory,
  };

  static PresetPane? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final profile = json['profile'];
    if (id is! String || id.isEmpty) return null;
    if (profile is! String || profile.isEmpty) return null;
    final cwd = json['cwd'];
    return PresetPane(
      id: id,
      profileId: profile,
      workingDirectory: cwd is String && cwd.isNotEmpty ? cwd : null,
    );
  }
}

/// One tab's shape: its regions and splits, and what each pane declares.
class PresetTab {
  const PresetTab({
    required this.layout,
    required this.focusedPaneId,
    required this.panes,
  });

  final PaneLayout layout;
  final String focusedPaneId;
  final List<PresetPane> panes;

  Map<String, Object?> toJson() => {
    'layout': layout.toJson(),
    'focused': focusedPaneId,
    'panes': [for (final pane in panes) pane.toJson()],
  };

  static PresetTab? fromJson(Object? json) {
    if (json is! Map) return null;
    final layout = PaneLayout.fromJson(json['layout']);
    final focused = json['focused'];
    final rawPanes = json['panes'];
    if (layout == null || focused is! String || rawPanes is! List) return null;
    final panes = <PresetPane>[
      for (final raw in rawPanes) ?PresetPane.fromJson(raw),
    ];
    // A tab whose tree names panes it does not declare cannot be opened, and
    // half of one is worse than none of it.
    final declared = {for (final pane in panes) pane.id};
    if (panes.isEmpty || !layout.panes.every(declared.contains)) return null;
    if (!layout.contains(focused)) return null;
    return PresetTab(layout: layout, focusedPaneId: focused, panes: panes);
  }
}

/// A named workbench shape — **never a live process.**
///
/// The distinction is the whole point of the feature. A preset that carried
/// running sessions would be a second, worse copy of the layout the app already
/// restores across a restart; what it carries instead is the *declaration* —
/// which regions, split which way, each holding a profile and a directory — so
/// opening one starts fresh panes rather than resurrecting old ones. Nothing
/// here holds scrollback, liveness, an exit code or a pane id the app will use.
///
/// Its lazy half is inherited rather than invented: opening a preset goes
/// through the same adoption a restart does, so only the tab that ends up in
/// front starts anything and the rest wait until somebody looks at them. See
/// `TerminalSessionsController.openPreset` and `shouldRestartOnActivate` —
/// *"a preset that launches nine processes is worse than no preset."*
class TerminalPreset {
  const TerminalPreset({
    required this.id,
    required this.name,
    required this.tabs,
    this.activeTab = 0,
  });

  final String id;
  final String name;
  final List<PresetTab> tabs;

  /// Which tab was in front when this was captured, as an index into [tabs].
  ///
  /// An index rather than a tab id because a preset's tabs have no ids of their
  /// own — they are shapes, and a shape is only ever addressed by its place.
  final int activeTab;

  int get paneCount => tabs.fold(0, (sum, tab) => sum + tab.panes.length);

  Map<String, Object?> toJson() => {
    'tabs': [for (final tab in tabs) tab.toJson()],
    'active': activeTab,
  };

  /// Parses a shape written by [toJson]. Returns `null` — never throws — for
  /// anything malformed, the rule every stored layout in this app follows.
  static TerminalPreset? fromJson({
    required String id,
    required String name,
    required Object? shape,
  }) {
    if (shape is! Map) return null;
    final rawTabs = shape['tabs'];
    if (rawTabs is! List) return null;
    final tabs = <PresetTab>[
      for (final raw in rawTabs) ?PresetTab.fromJson(raw),
    ];
    if (tabs.isEmpty) return null;
    final active = shape['active'];
    return TerminalPreset(
      id: id,
      name: name,
      tabs: tabs,
      activeTab: active is int && active >= 0 && active < tabs.length
          ? active
          : 0,
    );
  }
}

/// What opening a preset actually managed to do.
///
/// **The skipped list is the point.** A preset written on a machine with a WSL
/// distribution that has since been removed names a profile nothing can start,
/// and the app's restore path drops such a pane in silence — correct for a
/// restart nobody asked for, wrong for a thing the user just chose by name. So
/// opening reports what it left out, and the caller says so out loud.
class TerminalPresetOpening {
  const TerminalPresetOpening({
    required this.openedTabs,
    required this.openedPanes,
    required this.skippedProfileIds,
  });

  final int openedTabs;
  final int openedPanes;

  /// The profile ids no build of this app could resolve, in the order they were
  /// met, without repeats — the user needs the names, not the count.
  final List<String> skippedProfileIds;

  bool get skippedAnything => skippedProfileIds.isNotEmpty;
}

/// Rebuilds [layout] with fresh ids, so one preset can be opened twice.
///
/// Pane ids come from [paneId] — the caller keeps the same map for the tab's
/// declarations, so the tree and the panes agree — and every region and split
/// gets a new id from [nodeId], because those are identities for the widgets
/// that draw them and two tabs must never share one.
PaneLayout remapPaneIds(
  PaneLayout layout,
  String Function(String) paneId,
  String Function() nodeId,
) => PaneLayout(_remap(layout.root, paneId, nodeId));

PaneNode _remap(
  PaneNode node,
  String Function(String) paneId,
  String Function() nodeId,
) => switch (node) {
  PaneGroup(:final panes, :final activePaneId) => PaneGroup(
    nodeId(),
    panes: [for (final pane in panes) paneId(pane)],
    activePaneId: paneId(activePaneId),
  ),
  PaneSplit(:final axis, :final children, :final weights) => PaneSplit(
    nodeId(),
    axis: axis,
    children: [for (final child in children) _remap(child, paneId, nodeId)],
    weights: weights,
  ),
};
