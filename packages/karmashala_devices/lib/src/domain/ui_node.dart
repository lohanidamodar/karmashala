import 'device_input.dart';

/// A node's rectangle on screen, in **device pixels** — the space
/// `adb shell input tap` uses. Every tap by query is derived from it, and a
/// wrong centre taps the wrong thing while reporting success, so parsing is
/// strict.
class UiBounds {
  const UiBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  /// Parses uiautomator's `[left,top][right,bottom]`, or null for anything else.
  /// Coordinates may be negative: a node scrolled above the viewport reports one.
  static UiBounds? parse(String? raw) {
    if (raw == null) return null;
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    return UiBounds(
      left: int.parse(match.group(1)!),
      top: int.parse(match.group(2)!),
      right: int.parse(match.group(3)!),
      bottom: int.parse(match.group(4)!),
    );
  }

  static final RegExp _pattern = RegExp(
    r'^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$',
  );

  int get width => right - left;
  int get height => bottom - top;

  /// A zero-area rectangle cannot be tapped. Compose and Flutter both emit
  /// these for nodes that exist semantically but occupy no space.
  bool get isEmpty => width <= 0 || height <= 0;

  /// The point to tap. Integer division matches the arithmetic the pane's
  /// coordinate mapping was verified against.
  ({int x, int y}) get center =>
      (x: (left + right) ~/ 2, y: (top + bottom) ~/ 2);

  /// Whether the centre point lies inside a screen of [screen]. An off-screen
  /// node still appears in the dump, and tapping it hits whatever is there.
  bool centerIsOnScreen(DeviceScreenSize screen) {
    final c = center;
    return c.x >= 0 && c.y >= 0 && c.x < screen.width && c.y < screen.height;
  }

  /// Whether this node spans nearly the whole screen on both axes — the shape of
  /// a scrim, which Android puts behind every dialog. 90% per axis, not on area:
  /// a barrier can leave a sliver of one edge uncovered and still be one.
  bool coversMostOf(DeviceScreenSize screen, {double fraction = 0.9}) =>
      width >= screen.width * fraction && height >= screen.height * fraction;

  /// Whether ([x], [y]) is inside this rectangle. Right and bottom are exclusive,
  /// the way the device's hit test is: adjacent nodes share an edge.
  bool holds(int x, int y) => x >= left && x < right && y >= top && y < bottom;

  /// Area, for picking the innermost of several rectangles over one point.
  int get area => width <= 0 || height <= 0 ? 0 : width * height;

  /// The original `[l,t][r,b]` form, so a caller can echo exactly what the
  /// device reported.
  String get raw => '[$left,$top][$right,$bottom]';

  @override
  bool operator ==(Object other) =>
      other is UiBounds &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => raw;
}

/// One node of an Android view hierarchy, as `uiautomator dump` describes it.
/// Every attribute is optional in practice, so strings default to `''` and flags
/// to `false`; callers ask [hasText] rather than testing for null.
class UiNode {
  UiNode({
    this.index = 0,
    this.text = '',
    this.resourceId = '',
    this.className = '',
    this.packageName = '',
    this.contentDescription = '',
    this.bounds,
    this.checkable = false,
    this.checked = false,
    this.clickable = false,
    this.enabled = true,
    this.focusable = false,
    this.focused = false,
    this.scrollable = false,
    this.longClickable = false,
    this.password = false,
    this.selected = false,
    List<UiNode> children = const [],
  }) : children = List.unmodifiable(children) {
    for (final child in this.children) {
      child._parent = this;
    }
  }

  /// Position among siblings, as the device reported it.
  final int index;

  final String text;
  final String resourceId;
  final String className;
  final String packageName;
  final String contentDescription;
  final UiBounds? bounds;

  final bool checkable;
  final bool checked;
  final bool clickable;
  final bool enabled;
  final bool focusable;
  final bool focused;
  final bool scrollable;
  final bool longClickable;
  final bool password;
  final bool selected;

  final List<UiNode> children;

  UiNode? _parent;

  /// The node that contains this one, or `null` at the top of the tree.
  UiNode? get parent => _parent;

  bool get hasText => text.trim().isNotEmpty;
  bool get hasContentDescription => contentDescription.trim().isNotEmpty;

  /// What a human would call this node: its text, falling back to its
  /// content-description. **Flutter apps put their labels in `content-desc` and
  /// leave `text` empty**, so matching only `text` finds nothing on them.
  String get label => hasText ? text.trim() : contentDescription.trim();

  /// `resource-id` with the package prefix removed: `com.app:id/ok` -> `ok`.
  String get shortResourceId {
    final slash = resourceId.lastIndexOf('/');
    return slash < 0 ? resourceId : resourceId.substring(slash + 1);
  }

  /// Last segment of the class name: `android.widget.Button` -> `Button`.
  String get shortClassName {
    final dot = className.lastIndexOf('.');
    return dot < 0 ? className : className.substring(dot + 1);
  }

  /// Whether this node responds to input in some way.
  bool get isInteractable =>
      clickable || longClickable || scrollable || checkable;

  /// Whether the node is worth showing an agent by default. A full dump is mostly
  /// layout scaffolding, and dropping it is what makes the listing affordable.
  bool get isInteresting =>
      hasText || hasContentDescription || isInteractable || password;

  /// Depth below the top of the tree; a root node is 0.
  int get depth {
    var d = 0;
    for (var node = _parent; node != null; node = node._parent) {
      d++;
    }
    return d;
  }

  /// Positional path from the root, e.g. `0/3/1`. Built from real child
  /// positions: some OEM builds report the `index` attribute inconsistently.
  String get path {
    final segments = <int>[];
    var node = this;
    for (var parent = node._parent; parent != null; parent = node._parent) {
      segments.add(parent.children.indexOf(node));
      node = parent;
    }
    return segments.reversed.join('/');
  }

  /// This node and every descendant, in document order. Walked with an explicit
  /// stack: this is the hot path, and `yield*` costs O(depth) per step.
  Iterable<UiNode> get selfAndDescendants sync* {
    final stack = <UiNode>[this];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      yield node;
      for (var i = node.children.length - 1; i >= 0; i--) {
        stack.add(node.children[i]);
      }
    }
  }

  /// Ancestors from the immediate parent upwards.
  Iterable<UiNode> get ancestors sync* {
    for (var node = _parent; node != null; node = node._parent) {
      yield node;
    }
  }

  /// The bounds to tap. The node's own rectangle, or the nearest ancestor with
  /// area when it has none. Deliberately **not** the nearest clickable ancestor:
  /// in a list that is the list, whose centre is a different row.
  UiBounds? get tapBounds {
    final own = bounds;
    if (own != null && !own.isEmpty) return own;
    for (final ancestor in ancestors) {
      final b = ancestor.bounds;
      if (b != null && !b.isEmpty) return b;
    }
    return own;
  }

  @override
  String toString() =>
      'UiNode($shortClassName${label.isEmpty ? '' : ' "$label"'}'
      '${bounds == null ? '' : ' ${bounds!.raw}'})';
}

/// A parsed `uiautomator dump`: the top-level nodes plus the screen rotation.
class UiHierarchy {
  UiHierarchy({required List<UiNode> roots, this.rotation = 0})
    : roots = List.unmodifiable(roots);

  /// An empty tree — what a dump taken mid-animation can legitimately produce.
  static final UiHierarchy empty = UiHierarchy(roots: const []);

  final List<UiNode> roots;

  /// Screen rotation reported by the `<hierarchy>` element (0–3).
  final int rotation;

  bool get isEmpty => roots.isEmpty;

  /// Every node, in document order.
  Iterable<UiNode> get allNodes =>
      roots.expand((root) => root.selfAndDescendants);

  int get nodeCount => allNodes.length;

  /// The package that owns most of the tree — the foreground app, in practice.
  String? get packageName {
    final counts = <String, int>{};
    for (final node in allNodes) {
      if (node.packageName.isEmpty) continue;
      counts[node.packageName] = (counts[node.packageName] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    var best = counts.entries.first;
    for (final entry in counts.entries) {
      if (entry.value > best.value) best = entry;
    }
    return best.key;
  }

  /// Nodes matching [query], best match first. Exact label matches sort ahead of
  /// substring ones — `tap(text: "Settings")` means the title, not "Search
  /// settings".
  List<UiNode> find(UiElementQuery query, {int? limit}) {
    final matches = <UiNode>[];
    for (final node in allNodes) {
      if (query.matches(node)) matches.add(node);
    }
    // Rank, then restore document order within each rank: List.sort is not
    // stable, so the original position is the tie-breaker.
    final ordered =
        <({int rank, int position, UiNode node})>[
          for (var i = 0; i < matches.length; i++)
            (rank: query.rank(matches[i]), position: i, node: matches[i]),
        ]..sort((a, b) {
          final byRank = a.rank.compareTo(b.rank);
          return byRank != 0 ? byRank : a.position.compareTo(b.position);
        });
    final result = [for (final entry in ordered) entry.node];
    if (limit != null && result.length > limit) {
      return result.sublist(0, limit);
    }
    return result;
  }

  UiNode? findFirst(UiElementQuery query) {
    final found = find(query, limit: 1);
    return found.isEmpty ? null : found.first;
  }

  /// What a tap at ([x], [y]) would land on, or null. The smallest rectangle
  /// containing the point **approximates** the platform's hit test — a dump has
  /// no z-order. Used to describe what is under a coordinate, never to redirect.
  UiNode? at(int x, int y) {
    UiNode? best;
    var bestArea = -1;
    for (final node in allNodes) {
      final bounds = node.bounds;
      if (bounds == null || !bounds.holds(x, y)) continue;
      final area = bounds.area;
      if (best == null || area < bestArea) {
        best = node;
        bestArea = area;
      }
    }
    return best;
  }
}

/// A description of the element an agent is looking for. Every criterion must
/// match; matching is case-insensitive and substring-based by default, because
/// an agent reading a screenshot types what it saw.
class UiElementQuery {
  const UiElementQuery({
    this.text,
    this.resourceId,
    this.contentDescription,
    this.className,
    this.exact = false,
    this.clickableOnly = false,
    this.enabledOnly = false,
  });

  /// Matched against the node's **text or content-description** — see
  /// [UiNode.label] for why both.
  final String? text;

  /// Matched against `resource-id`, either in full (`com.app:id/ok`) or by its
  /// short form (`ok`), which is what a developer actually knows.
  final String? resourceId;

  /// Matched against `content-desc` only.
  final String? contentDescription;

  /// Matched against the class name, in full or by its last segment.
  final String? className;

  /// Require whole-value equality instead of a substring match. Still
  /// case-insensitive, and still trimmed.
  final bool exact;

  final bool clickableOnly;
  final bool enabledOnly;

  bool get isEmpty =>
      text == null &&
      resourceId == null &&
      contentDescription == null &&
      className == null;

  bool matches(UiNode node) {
    if (clickableOnly && !node.clickable && !node.longClickable) return false;
    if (enabledOnly && !node.enabled) return false;
    if (text case final needle?) {
      if (!_matchesAny(needle, [node.text, node.contentDescription])) {
        return false;
      }
    }
    if (contentDescription case final needle?) {
      if (!_matches(needle, node.contentDescription)) return false;
    }
    if (resourceId case final needle?) {
      if (!_matchesAny(needle, [node.resourceId, node.shortResourceId])) {
        return false;
      }
    }
    if (className case final needle?) {
      if (!_matchesAny(needle, [node.className, node.shortClassName])) {
        return false;
      }
    }
    return true;
  }

  /// 0 when every supplied criterion matches exactly, 1 otherwise — the sort key
  /// that puts "Settings" ahead of "Search settings". It covers every criterion:
  /// `contentDesc: "a"` once ranked a clock widget above the "a" key.
  int rank(UiNode node) {
    var criteria = 0;
    var exactHits = 0;
    void check(String? needle, List<String> candidates) {
      if (needle == null) return;
      criteria++;
      final a = needle.trim().toLowerCase();
      for (final candidate in candidates) {
        if (candidate.trim().toLowerCase() == a) {
          exactHits++;
          return;
        }
      }
    }

    check(text, [node.text, node.contentDescription]);
    check(contentDescription, [node.contentDescription]);
    check(resourceId, [node.resourceId, node.shortResourceId]);
    check(className, [node.className, node.shortClassName]);
    if (criteria == 0) return 1;
    return exactHits == criteria ? 0 : 1;
  }

  bool _matchesAny(String needle, List<String> candidates) {
    for (final candidate in candidates) {
      if (_matches(needle, candidate)) return true;
    }
    return false;
  }

  bool _matches(String needle, String value) {
    final a = needle.trim().toLowerCase();
    final b = value.trim().toLowerCase();
    if (a.isEmpty) return true;
    if (b.isEmpty) return false;
    return exact ? a == b : b.contains(a);
  }

  @override
  String toString() {
    final parts = <String>[
      if (text case final v?) 'text="$v"',
      if (contentDescription case final v?) 'desc="$v"',
      if (resourceId case final v?) 'id="$v"',
      if (className case final v?) 'class="$v"',
      if (exact) 'exact',
      if (clickableOnly) 'clickable',
      if (enabledOnly) 'enabled',
    ];
    return parts.isEmpty ? 'any element' : parts.join(' ');
  }
}
