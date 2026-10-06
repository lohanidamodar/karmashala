/// How a [PaneSplit] arranges its children: [horizontal] lays them out left to
/// right (a `Row`, "split right"); [vertical] stacks them top to bottom.
enum SplitAxis { horizontal, vertical }

/// A direction to move pane focus in.
enum PaneDirection { left, right, up, down }

/// Smallest share of its split a pane may be resized down to.
const double kMinPaneWeight = 0.05;

/// A node in a tab's pane tree: either a region ([PaneGroup]) or a division of
/// space between two or more nodes ([PaneSplit]).
sealed class PaneNode {
  const PaneNode(this.id);

  /// For a group this is a generated region id; for a split it is a generated
  /// id used to address the split when resizing. Never a pane id.
  final String id;
}

/// One **region**: the panes stacked in one part of a tab, and which is on top.
/// Never empty — an *empty region* holds one pane id with nothing behind it.
class PaneGroup extends PaneNode {
  PaneGroup(super.id, {required this.panes, String? activePaneId})
    : assert(panes.isNotEmpty, 'a region with no panes is not a region'),
      // Clamped here rather than at every call site: pruning, closing and
      // restoring can all take the front pane away, and whatever is left comes
      // forward.
      activePaneId = (activePaneId != null && panes.contains(activePaneId))
          ? activePaneId
          : panes.first;

  /// A region holding [paneId] alone.
  factory PaneGroup.of(String paneId, {String? id}) =>
      PaneGroup(id ?? regionIdFor(paneId), panes: [paneId]);

  /// The panes in this region, in the order their tabs are shown.
  final List<String> panes;

  /// The pane actually on screen. Always one of [panes].
  final String activePaneId;

  @override
  String toString() => 'PaneGroup($id, $panes, active: $activePaneId)';
}

/// The region id a lone pane gets when nobody supplies one. Derived rather than
/// generated so [PaneLayout.single] keeps its one-argument shape, and prefixed
/// so a region id can never be mistaken for the pane id it came from.
String regionIdFor(String paneId) => 'r:$paneId';

/// Space divided along [axis] between [children] in proportion to [weights].
/// After normalization there are always at least two children, and the weights
/// have the same length as the children and sum to 1.
class PaneSplit extends PaneNode {
  const PaneSplit(
    super.id, {
    required this.axis,
    required this.children,
    required this.weights,
  });

  final SplitAxis axis;
  final List<PaneNode> children;
  final List<double> weights;

  @override
  String toString() =>
      'PaneSplit($id, ${axis.name}, ${children.length} children)';
}

/// A region's share of its tab, in normalized `0..1` coordinates.
class PaneRect {
  const PaneRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  @override
  String toString() => 'PaneRect($left, $top, $right, $bottom)';
}

/// The immutable tree of regions inside one terminal tab. Free of Flutter and
/// of the terminal itself, and everything is addressed by pane id.
class PaneLayout {
  PaneLayout(this.root);

  /// A layout holding a single pane in a region of its own.
  factory PaneLayout.single(String paneId, {String? groupId}) =>
      PaneLayout(PaneGroup.of(paneId, id: groupId));

  final PaneNode root;

  /// Every region, depth-first, left to right.
  late final List<PaneGroup> groups = _collectGroups(root, <PaneGroup>[]);

  /// Pane ids depth-first, including the ones stacked behind another. Walked
  /// once and kept, because a layout is immutable and this is asked for often.
  late final List<String> panes = [for (final group in groups) ...group.panes];

  /// The pane on screen in each region — what "on screen" means once a region
  /// can hold more than one pane.
  late final List<String> visiblePanes = [
    for (final group in groups) group.activePaneId,
  ];

  late final Map<String, PaneGroup> _groupByPane = {
    for (final group in groups)
      for (final paneId in group.panes) paneId: group,
  };

  bool contains(String paneId) => _groupByPane.containsKey(paneId);

  /// The region [paneId] is in, or `null` when this layout does not hold it.
  PaneGroup? groupOf(String paneId) => _groupByPane[paneId];

  /// Divides the region holding [paneId] along [axis]. Always created nested;
  /// normalization flattens same-axis splits into one row of equal columns.
  PaneLayout split(
    String paneId,
    SplitAxis axis,
    String newPaneId,
    String splitId, {
    bool insertBefore = false,
  }) => splitWithNode(
    paneId,
    axis,
    PaneGroup.of(newPaneId),
    splitId,
    insertBefore: insertBefore,
  );

  /// Divides the region holding [paneId] along [axis], putting [newNode]
  /// after (or before if [insertBefore] is true) it.
  PaneLayout splitWithNode(
    String paneId,
    SplitAxis axis,
    PaneNode newNode,
    String splitId, {
    bool insertBefore = false,
  }) {
    if (!contains(paneId)) return this;
    final replaced = _splitIn(
      root,
      paneId,
      axis,
      newNode,
      splitId,
      insertBefore: insertBefore,
    );
    final normalized = _normalize(replaced);
    return normalized == null ? this : PaneLayout(normalized);
  }

  /// Puts [paneIds] into the region holding [targetPaneId] and brings the last
  /// of them to the front — what dropping a tab onto a region's header is made
  /// of. The caller owns uniqueness: nothing in [paneIds] may already be here.
  PaneLayout addPanes(String targetPaneId, List<String> paneIds) {
    if (paneIds.isEmpty || !contains(targetPaneId)) return this;
    return PaneLayout(
      _mapGroups(
        root,
        (group) => group.panes.contains(targetPaneId)
            ? PaneGroup(
                group.id,
                panes: [...group.panes, ...paneIds],
                activePaneId: paneIds.last,
              )
            : group,
      ),
    );
  }

  /// [addPanes] for one pane.
  PaneLayout addPane(String targetPaneId, String paneId) =>
      addPanes(targetPaneId, [paneId]);

  /// Puts [paneId] into the region holding [anchorPaneId], right after it or,
  /// [atEnd], last — and leaves that region's front pane in front.
  PaneLayout insertBehind(
    String anchorPaneId,
    String paneId, {
    bool atEnd = false,
  }) {
    final group = groupOf(anchorPaneId);
    if (group == null || contains(paneId)) return this;
    final panes = List.of(group.panes);
    if (atEnd) {
      panes.add(paneId);
    } else {
      panes.insert(panes.indexOf(anchorPaneId) + 1, paneId);
    }
    return PaneLayout(
      _mapGroups(
        root,
        (candidate) => identical(candidate, group)
            ? PaneGroup(
                group.id,
                panes: panes,
                activePaneId: group.activePaneId,
              )
            : candidate,
      ),
    );
  }

  /// The region with [groupId], or `null` when this layout has none.
  PaneGroup? groupById(String groupId) {
    for (final group in groups) {
      if (group.id == groupId) return group;
    }
    return null;
  }

  /// Moves [paneId] to [toIndex] within its own region, leaving the tree's
  /// shape and the front pane alone — dragging a tab along the strip it is
  /// already in. The tree is untouched, so nothing is normalized.
  PaneLayout reorderInGroup(String paneId, int toIndex) {
    final group = groupOf(paneId);
    if (group == null || group.panes.length < 2) return this;
    final from = group.panes.indexOf(paneId);
    final to = toIndex.clamp(0, group.panes.length - 1);
    if (from == to) return this;
    final panes = List.of(group.panes)
      ..removeAt(from)
      ..insert(to, paneId);
    return PaneLayout(
      _mapGroups(
        root,
        (candidate) => identical(candidate, group)
            ? PaneGroup(
                group.id,
                panes: panes,
                activePaneId: group.activePaneId,
              )
            : candidate,
      ),
    );
  }

  /// Brings [paneId] to the front of its own region. The layout's shape does
  /// not change, so nothing is normalized.
  PaneLayout activate(String paneId) {
    final group = groupOf(paneId);
    if (group == null || group.activePaneId == paneId) return this;
    return PaneLayout(
      _mapGroups(
        root,
        (candidate) => identical(candidate, group)
            ? PaneGroup(group.id, panes: group.panes, activePaneId: paneId)
            : candidate,
      ),
    );
  }

  /// Puts [node] where the region holding [paneId] is — what fills an *empty
  /// region*. The caller owns uniqueness: [node] may hold no pane already here.
  PaneLayout replaceRegion(String paneId, PaneNode node) {
    final group = groupOf(paneId);
    if (group == null) return this;
    final normalized = _normalize(_replaceGroupIn(root, group, node));
    return normalized == null ? this : PaneLayout(normalized);
  }

  /// Removes [paneId], collapsing its region and every split that leaves
  /// pointless. `null` when it was the last pane in the tab.
  PaneLayout? close(String paneId) {
    if (!contains(paneId)) return this;
    final removed = _prune(root, (id) => id != paneId);
    if (removed == null) return null;
    final normalized = _normalize(removed);
    return normalized == null ? null : PaneLayout(normalized);
  }

  /// Drops every pane whose id is not in [keep] — used when restoring a stored
  /// layout whose panes could not all be recreated. A region left with nothing
  /// goes with them.
  PaneLayout? withoutMissing(Set<String> keep) {
    final pruned = _prune(root, keep.contains);
    if (pruned == null) return null;
    final normalized = _normalize(pruned);
    return normalized == null ? null : PaneLayout(normalized);
  }

  /// Moves [delta] of the split's width from child `index + 1` to child [index],
  /// clamped so neither drops below [kMinPaneWeight].
  PaneLayout resize(String splitId, int index, double delta) {
    final resized = _resizeIn(root, splitId, index, delta);
    return resized == null ? this : PaneLayout(resized);
  }

  String? nextPane(String from) => _step(from, 1);

  String? previousPane(String from) => _step(from, -1);

  String? _step(String from, int by) {
    final all = panes;
    final index = all.indexOf(from);
    if (index < 0) return null;
    return all[(index + by + all.length) % all.length];
  }

  /// The pane on screen next to [from] in [direction], or `null` at the edge.
  /// From geometry, not tree structure — past two levels they disagree.
  String? paneInDirection(String from, PaneDirection direction) {
    final all = rects();
    final source = all[from];
    if (source == null) return null;

    const epsilon = 1e-6;
    final midX = (source.left + source.right) / 2;
    final midY = (source.top + source.bottom) / 2;
    final (double x, double y) = switch (direction) {
      PaneDirection.left => (source.left - epsilon, midY),
      PaneDirection.right => (source.right + epsilon, midY),
      PaneDirection.up => (midX, source.top - epsilon),
      PaneDirection.down => (midX, source.bottom + epsilon),
    };
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;

    final origin = groupOf(from);
    for (final entry in all.entries) {
      final group = _groupByPane[entry.key];
      if (group == null || identical(group, origin)) continue;
      final rect = entry.value;
      if (x >= rect.left &&
          x < rect.right &&
          y >= rect.top &&
          y < rect.bottom) {
        return group.activePaneId;
      }
    }
    return null;
  }

  /// Each pane's rectangle within the unit square. Everything stacked in one
  /// region shares that region's rectangle.
  Map<String, PaneRect> rects() {
    final result = <String, PaneRect>{};
    _fillRects(root, const PaneRect(0, 0, 1, 1), result);
    return result;
  }

  Map<String, Object?> toJson() => _toJson(root);

  /// Parses a layout written by [toJson]. Returns `null` — never throws — for
  /// anything malformed, so a corrupt stored row degrades to "no layout".
  static PaneLayout? fromJson(Object? json) {
    final node = _fromJson(json);
    return node == null ? null : PaneLayout(node);
  }

  @override
  String toString() => 'PaneLayout($root)';
}

// --- Tree operations ---------------------------------------------------------

List<PaneGroup> _collectGroups(PaneNode node, List<PaneGroup> out) {
  switch (node) {
    case PaneGroup():
      out.add(node);
    case PaneSplit():
      for (final child in node.children) {
        _collectGroups(child, out);
      }
  }
  return out;
}

/// Rebuilds [node] with [map] applied to every region.
PaneNode _mapGroups(PaneNode node, PaneGroup Function(PaneGroup) map) {
  switch (node) {
    case PaneGroup():
      return map(node);
    case PaneSplit():
      return PaneSplit(
        node.id,
        axis: node.axis,
        children: [for (final child in node.children) _mapGroups(child, map)],
        weights: List.of(node.weights),
      );
  }
}

PaneNode _splitIn(
  PaneNode node,
  String paneId,
  SplitAxis axis,
  PaneNode newNode,
  String splitId, {
  bool insertBefore = false,
}) {
  switch (node) {
    case PaneGroup():
      if (!node.panes.contains(paneId)) return node;
      return PaneSplit(
        splitId,
        axis: axis,
        children: insertBefore ? [newNode, node] : [node, newNode],
        weights: const [0.5, 0.5],
      );
    case PaneSplit():
      return PaneSplit(
        node.id,
        axis: node.axis,
        children: [
          for (final child in node.children)
            _splitIn(
              child,
              paneId,
              axis,
              newNode,
              splitId,
              insertBefore: insertBefore,
            ),
        ],
        weights: List.of(node.weights),
      );
  }
}

PaneNode _replaceGroupIn(
  PaneNode node,
  PaneGroup target,
  PaneNode replacement,
) {
  switch (node) {
    case PaneGroup():
      return identical(node, target) ? replacement : node;
    case PaneSplit():
      return PaneSplit(
        node.id,
        axis: node.axis,
        children: [
          for (final child in node.children)
            _replaceGroupIn(child, target, replacement),
        ],
        weights: List.of(node.weights),
      );
  }
}

/// Rebuilds [node] keeping only panes for which [keep] holds, and only the
/// regions that still hold one.
PaneNode? _prune(PaneNode node, bool Function(String paneId) keep) {
  switch (node) {
    case PaneGroup():
      final panes = [
        for (final paneId in node.panes)
          if (keep(paneId)) paneId,
      ];
      if (panes.isEmpty) return null;
      // The front pane may have been one of the dropped ones; the constructor
      // brings whatever is left forward rather than leaving a dangling id.
      return PaneGroup(node.id, panes: panes, activePaneId: node.activePaneId);
    case PaneSplit():
      final children = <PaneNode>[];
      final weights = <double>[];
      for (var i = 0; i < node.children.length; i++) {
        final child = _prune(node.children[i], keep);
        if (child == null) continue;
        children.add(child);
        weights.add(node.weights[i]);
      }
      if (children.isEmpty) return null;
      return PaneSplit(
        node.id,
        axis: node.axis,
        children: children,
        weights: weights,
      );
  }
}

/// Collapses single-child splits, flattens same-axis nesting and renormalizes
/// weights, bottom-up. Idempotent.
PaneNode? _normalize(PaneNode node) {
  switch (node) {
    case PaneGroup():
      return node;
    case PaneSplit():
      final children = <PaneNode>[];
      final weights = <double>[];
      for (var i = 0; i < node.children.length; i++) {
        final child = _normalize(node.children[i]);
        if (child == null) continue;
        final weight = node.weights[i];
        if (child is PaneSplit && child.axis == node.axis) {
          for (var j = 0; j < child.children.length; j++) {
            children.add(child.children[j]);
            weights.add(weight * child.weights[j]);
          }
        } else {
          children.add(child);
          weights.add(weight);
        }
      }
      if (children.isEmpty) return null;
      if (children.length == 1) return children.first;
      return PaneSplit(
        node.id,
        axis: node.axis,
        children: children,
        weights: _renormalized(weights),
      );
  }
}

List<double> _renormalized(List<double> weights) {
  var total = 0.0;
  for (final weight in weights) {
    total += weight;
  }
  if (total <= 0) {
    return List.filled(weights.length, 1 / weights.length);
  }
  return [for (final weight in weights) weight / total];
}

/// Returns the rebuilt tree, or `null` when [splitId] was not found.
PaneNode? _resizeIn(PaneNode node, String splitId, int index, double delta) {
  if (node is! PaneSplit) return null;

  if (node.id == splitId) {
    if (index < 0 || index + 1 >= node.weights.length) return null;
    final pair = node.weights[index] + node.weights[index + 1];
    final lower = kMinPaneWeight;
    final upper = pair - kMinPaneWeight;
    if (upper < lower) return null;
    final first = (node.weights[index] + delta).clamp(lower, upper);
    final weights = List.of(node.weights);
    weights[index] = first;
    weights[index + 1] = pair - first;
    return PaneSplit(
      node.id,
      axis: node.axis,
      children: node.children,
      weights: weights,
    );
  }

  for (var i = 0; i < node.children.length; i++) {
    final resized = _resizeIn(node.children[i], splitId, index, delta);
    if (resized == null) continue;
    final children = List.of(node.children);
    children[i] = resized;
    return PaneSplit(
      node.id,
      axis: node.axis,
      children: children,
      weights: List.of(node.weights),
    );
  }
  return null;
}

void _fillRects(PaneNode node, PaneRect rect, Map<String, PaneRect> out) {
  switch (node) {
    case PaneGroup():
      // Every pane stacked in a region occupies the region: only one of them
      // is drawn, but "where is this pane" has the same answer for all of them.
      for (final paneId in node.panes) {
        out[paneId] = rect;
      }
    case PaneSplit():
      var offset = 0.0;
      for (var i = 0; i < node.children.length; i++) {
        final weight = node.weights[i];
        final child = switch (node.axis) {
          SplitAxis.horizontal => PaneRect(
            rect.left + rect.width * offset,
            rect.top,
            rect.left + rect.width * (offset + weight),
            rect.bottom,
          ),
          SplitAxis.vertical => PaneRect(
            rect.left,
            rect.top + rect.height * offset,
            rect.right,
            rect.top + rect.height * (offset + weight),
          ),
        };
        _fillRects(node.children[i], child, out);
        offset += weight;
      }
  }
}

// --- JSON --------------------------------------------------------------------

Map<String, Object?> _toJson(PaneNode node) => switch (node) {
  PaneGroup() => {
    't': 'group',
    'id': node.id,
    'p': node.panes,
    'a': node.activePaneId,
  },
  PaneSplit() => {
    't': 'split',
    'id': node.id,
    'axis': node.axis == SplitAxis.horizontal ? 'h' : 'v',
    'w': node.weights,
    'c': [for (final child in node.children) _toJson(child)],
  },
};

PaneNode? _fromJson(Object? json) {
  if (json is! Map) return null;
  final id = json['id'];
  if (id is! String || id.isEmpty) return null;

  switch (json['t']) {
    // Written before regions existed: one leaf was one pane. Read as a region
    // of one rather than dropped, so upgrading does not throw a layout away.
    case 'leaf':
      return PaneGroup.of(id);
    case 'group':
      final rawPanes = json['p'];
      if (rawPanes is! List || rawPanes.isEmpty) return null;
      final panes = <String>[];
      for (final paneId in rawPanes) {
        if (paneId is! String || paneId.isEmpty) return null;
        panes.add(paneId);
      }
      final active = json['a'];
      return PaneGroup(
        id,
        panes: panes,
        activePaneId: active is String ? active : null,
      );
    case 'split':
      final axis = switch (json['axis']) {
        'h' => SplitAxis.horizontal,
        'v' => SplitAxis.vertical,
        _ => null,
      };
      final rawWeights = json['w'];
      final rawChildren = json['c'];
      if (axis == null || rawWeights is! List || rawChildren is! List) {
        return null;
      }
      if (rawChildren.length < 2 || rawWeights.length != rawChildren.length) {
        return null;
      }
      final weights = <double>[];
      for (final weight in rawWeights) {
        if (weight is! num) return null;
        weights.add(weight.toDouble());
      }
      final children = <PaneNode>[];
      for (final child in rawChildren) {
        final parsed = _fromJson(child);
        if (parsed == null) return null;
        children.add(parsed);
      }
      return PaneSplit(id, axis: axis, children: children, weights: weights);
    default:
      return null;
  }
}
