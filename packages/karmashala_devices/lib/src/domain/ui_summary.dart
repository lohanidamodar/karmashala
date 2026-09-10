import 'device_input.dart';
import 'ui_node.dart';

/// Renders a [UiHierarchy] for an agent to read. The point is token cost: a raw
/// dump of an ordinary screen is ~23 000 characters of XML, nearly all repeated
/// attribute names on layout containers an agent can do nothing with.

/// One line explaining the line format, emitted once per listing.
const String uiListingLegend =
    'Format: (tapX,tapY) WxH Class "text" ~"content-desc" #resource-id '
    '[flags] · flags: c=clickable L=long-clickable s=scrollable k=checkable '
    'K=checked S=selected f=focused D=disabled P=password o=off-screen';

/// Longest text or content-description rendered before it is elided.
const int _maxLabelLength = 80;

/// One node as a single line. Coordinates come first because they are what the
/// caller acts on; a node whose centre falls outside [screen] is flagged `o`,
/// because tapping a scrolled-away node hits whatever is really there.
String describeUiNode(UiNode node, {DeviceScreenSize? screen}) {
  final buffer = StringBuffer();
  final bounds = node.tapBounds;
  if (bounds == null) {
    buffer.write('(no bounds)');
  } else {
    final c = bounds.center;
    buffer.write('(${c.x},${c.y}) ${bounds.width}x${bounds.height}');
  }
  if (node.shortClassName.isNotEmpty) {
    buffer.write(' ${node.shortClassName}');
  }
  if (node.text.trim().isNotEmpty) {
    buffer.write(' "${_escape(node.text)}"');
  }
  final desc = node.contentDescription.trim();
  if (desc.isNotEmpty && desc != node.text.trim()) {
    buffer.write(' ~"${_escape(desc)}"');
  }
  if (node.shortResourceId.isNotEmpty) {
    buffer.write(' #${node.shortResourceId}');
  }
  final flags = _flags(node, screen: screen);
  if (flags.isNotEmpty) buffer.write(' [$flags]');
  return buffer.toString();
}

String _flags(UiNode node, {DeviceScreenSize? screen}) {
  final buffer = StringBuffer();
  if (node.clickable) buffer.write('c');
  if (node.longClickable) buffer.write('L');
  if (node.scrollable) buffer.write('s');
  if (node.checkable) buffer.write('k');
  if (node.checked) buffer.write('K');
  if (node.selected) buffer.write('S');
  if (node.focused) buffer.write('f');
  if (!node.enabled) buffer.write('D');
  if (node.password) buffer.write('P');
  if (screen != null) {
    final bounds = node.tapBounds;
    if (bounds == null || !bounds.centerIsOnScreen(screen)) buffer.write('o');
  }
  return buffer.toString();
}

/// Collapses a value onto one line and caps its length, so one node is always
/// exactly one line: real content-descriptions contain newlines.
String _escape(String value) {
  final flat = value
      .trim()
      .replaceAll(RegExp(r'\r\n|\r|\n'), r'\n')
      .replaceAll('\t', r'\t')
      .replaceAll('"', r'\"');
  if (flat.length <= _maxLabelLength) return flat;
  return '${flat.substring(0, _maxLabelLength)}…';
}

/// The pruned listing: one line per node that carries text or accepts input.
/// [limit] caps it, and [truncated] says how many were dropped.
({String listing, int shown, int truncated}) renderUiElements(
  List<UiNode> nodes, {
  DeviceScreenSize? screen,
  int? limit,
}) {
  final shown = limit == null || nodes.length <= limit
      ? nodes
      : nodes.sublist(0, limit);
  return (
    listing: [
      for (final node in shown) describeUiNode(node, screen: screen),
    ].join('\n'),
    shown: shown.length,
    truncated: nodes.length - shown.length,
  );
}

/// The full tree: every node, indented by depth. Worth asking for only when the
/// pruned listing missed something — a custom view with no text or flags.
String renderUiTree(UiHierarchy hierarchy, {DeviceScreenSize? screen}) {
  final lines = <String>[];
  for (final root in hierarchy.roots) {
    _writeTree(root, lines, screen: screen);
  }
  return lines.join('\n');
}

void _writeTree(UiNode node, List<String> lines, {DeviceScreenSize? screen}) {
  lines.add('${'  ' * node.depth}${describeUiNode(node, screen: screen)}');
  for (final child in node.children) {
    _writeTree(child, lines, screen: screen);
  }
}

/// The nodes worth listing by default: text-bearing or interactable.
List<UiNode> interestingNodes(UiHierarchy hierarchy) => [
  for (final node in hierarchy.allNodes)
    if (node.isInteresting) node,
];

/// A leaf big enough to be the screen that reports no text at all: a painted
/// surface appears as one empty `View` with its content simply absent, and a
/// dump saying "5 of 17 nodes" then reads like a success rather than a blind
/// spot. Returns the offending node so the caller can point at it, or null.
UiNode? canvasLikeNode(UiHierarchy hierarchy, DeviceScreenSize? screen) {
  if (screen == null) return null;
  final area = screen.width * screen.height;
  if (area <= 0) return null;
  UiNode? biggest;
  var biggestArea = 0;
  for (final node in hierarchy.allNodes) {
    if (node.children.isNotEmpty) continue;
    if (node.text.trim().isNotEmpty) continue;
    if (node.contentDescription.trim().isNotEmpty) continue;
    final bounds = node.bounds;
    if (bounds == null || bounds.isEmpty) continue;
    final nodeArea = bounds.width * bounds.height;
    if (nodeArea * 4 < area) continue; // under a quarter of the screen
    if (nodeArea > biggestArea) {
      biggest = node;
      biggestArea = nodeArea;
    }
  }
  return biggest;
}
