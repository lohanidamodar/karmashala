// A named layout, and nothing that is running in it.

import 'pane_layout.dart';

/// One pane's declaration inside a preset: what to start there, and where.
/// [id] is the pane id the preset's own [PresetTab.layout] refers to, not a
/// pane id in the app — opening a preset mints fresh ones — but the tree has to
/// name its leaves somehow.
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
/// A preset that carried running sessions would be a second, worse copy of the
/// layout the app already restores across a restart; what it carries is the
/// *declaration*, so opening one starts fresh panes and nothing here holds
/// scrollback, liveness or a pane id the app will use. Opening goes through the
/// same lazy adoption a restart does — *"a preset that launches nine processes
/// is worse than no preset."*
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

  /// Which tab was in front when this was captured, as an index into [tabs] —
  /// a preset's tabs have no ids of their own, being shapes, and a shape is
  /// only ever addressed by its place.
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
/// **The skipped list is the point.** A preset naming a profile nothing can
/// start — a WSL distribution since removed — would be dropped in silence by
/// the restore path, which is wrong for a thing the user just chose by name, so
/// opening reports what it left out.
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

/// Rebuilds [layout] with fresh ids, so one preset can be opened twice. Pane
/// ids come from [paneId] — the caller keeps one map, so the tree and the panes
/// agree — and every region and split gets a new id from [nodeId], because two
/// tabs must never share a widget identity.
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
