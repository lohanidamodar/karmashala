/// How a [PaneSplit] arranges its children.
///
/// Stated once so it is never re-derived: [horizontal] lays children out left to
/// right (a `Row`, colloquially "split right"); [vertical] stacks them top to
/// bottom (a `Column`, "split down").
enum SplitAxis { horizontal, vertical }

/// A direction to move pane focus in.
enum PaneDirection { left, right, up, down }

/// Smallest share of its split a pane may be resized down to.
const double kMinPaneWeight = 0.05;

/// A node in a tab's pane tree: either a terminal ([PaneLeaf]) or a division of
/// space between two or more nodes ([PaneSplit]).
sealed class PaneNode {
  const PaneNode(this.id);

  /// For a leaf this is the `TerminalInstance` id; for a split it is a generated
  /// id used to address the split when resizing.
  final String id;
}

/// One terminal.
class PaneLeaf extends PaneNode {
  const PaneLeaf(super.id);

  @override
  String toString() => 'PaneLeaf($id)';
}

/// Space divided along [axis] between [children] in proportion to [weights].
///
/// After normalization there are always at least two children, `weights` has the
/// same length as `children`, and the weights sum to 1.
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

/// A pane's share of its tab, in normalized `0..1` coordinates.
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

/// The immutable tree of panes inside one terminal tab, plus the operations the
/// UI drives it with.
///
/// Deliberately free of Flutter, Riverpod and the terminal itself, so splitting,
/// closing and focus traversal are unit-testable without a widget tree. Every
/// operation returns a new layout; nothing here mutates.
class PaneLayout {
  PaneLayout(this.root);

  /// A layout holding a single pane.
  factory PaneLayout.single(String paneId) => PaneLayout(PaneLeaf(paneId));

  final PaneNode root;

  /// Pane ids in depth-first, left-to-right order.
  ///
  /// Walked once and kept. A layout is immutable — every operation returns a
  /// new one — so the answer cannot go stale, and it is asked for constantly:
  /// once per tab on every publish to set ingest tiers, and again inside every
  /// [contains]. Rebuilding the list each time made "which tab holds this
  /// pane?" allocate a list per tab per lookup.
  ///
  /// Treat as read-only.
  late final List<String> panes = _collect(root, <String>[]);

  late final Set<String> _paneIds = panes.toSet();

  bool contains(String paneId) => _paneIds.contains(paneId);

  /// Divides [paneId] along [axis], putting [newPaneId] after it.
  ///
  /// The new split is always created nested; normalization then flattens it into
  /// the parent when the axes match, which is what turns a second "split right"
  /// into a third equal column rather than a right-leaning spine.
  PaneLayout split(
    String paneId,
    SplitAxis axis,
    String newPaneId,
    String splitId,
  ) {
    if (!contains(paneId)) return this;
    final replaced = _splitIn(root, paneId, axis, newPaneId, splitId);
    final normalized = _normalize(replaced);
    return normalized == null ? this : PaneLayout(normalized);
  }

  /// Removes [paneId], collapsing every split it leaves pointless.
  ///
  /// Returns `null` when it was the last pane.
  PaneLayout? close(String paneId) {
    if (!contains(paneId)) return this;
    final removed = _prune(root, (id) => id != paneId);
    if (removed == null) return null;
    final normalized = _normalize(removed);
    return normalized == null ? null : PaneLayout(normalized);
  }

  /// Drops every leaf whose id is not in [keep] — used when restoring a stored
  /// layout whose panes could not all be recreated.
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

  /// The pane adjacent to [from] in [direction], or `null` at the layout's edge.
  ///
  /// Answered from geometry rather than tree structure: past two levels of
  /// nesting the tree sibling is frequently not the pane the user sees next to
  /// this one.
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

    for (final entry in all.entries) {
      if (entry.key == from) continue;
      final rect = entry.value;
      if (x >= rect.left &&
          x < rect.right &&
          y >= rect.top &&
          y < rect.bottom) {
        return entry.key;
      }
    }
    return null;
  }

  /// Each pane's rectangle within the unit square.
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

List<String> _collect(PaneNode node, List<String> out) {
  switch (node) {
    case PaneLeaf():
      out.add(node.id);
    case PaneSplit():
      for (final child in node.children) {
        _collect(child, out);
      }
  }
  return out;
}

PaneNode _splitIn(
  PaneNode node,
  String paneId,
  SplitAxis axis,
  String newPaneId,
  String splitId,
) {
  switch (node) {
    case PaneLeaf():
      if (node.id != paneId) return node;
      return PaneSplit(
        splitId,
        axis: axis,
        children: [node, PaneLeaf(newPaneId)],
        weights: const [0.5, 0.5],
      );
    case PaneSplit():
      return PaneSplit(
        node.id,
        axis: node.axis,
        children: [
          for (final child in node.children)
            _splitIn(child, paneId, axis, newPaneId, splitId),
        ],
        weights: List.of(node.weights),
      );
  }
}

/// Rebuilds [node] keeping only leaves for which [keep] holds.
PaneNode? _prune(PaneNode node, bool Function(String paneId) keep) {
  switch (node) {
    case PaneLeaf():
      return keep(node.id) ? node : null;
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
    case PaneLeaf():
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
    case PaneLeaf():
      out[node.id] = rect;
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
  PaneLeaf() => {'t': 'leaf', 'id': node.id},
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
    case 'leaf':
      return PaneLeaf(id);
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
