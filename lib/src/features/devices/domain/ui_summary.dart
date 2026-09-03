import 'device_input.dart';
import 'ui_node.dart';

/// Renders a [UiHierarchy] for an agent to read.
///
/// The point of this file is token cost. A raw `uiautomator dump` of an
/// ordinary screen is ~23 000 characters of XML — several thousand tokens,
/// nearly all of it repeated attribute names on layout containers that an agent
/// can do nothing with. Pruning to nodes that carry text or accept input, and
/// writing one line per node with the empty fields dropped, cuts that by well
/// over an order of magnitude while keeping everything needed to choose and hit
/// a target.

/// One line explaining the line format, emitted once per listing.
const String uiListingLegend =
    'Format: (tapX,tapY) WxH Class "text" ~"content-desc" #resource-id '
    '[flags] · flags: c=clickable L=long-clickable s=scrollable k=checkable '
    'K=checked S=selected f=focused D=disabled P=password o=off-screen';

/// Longest text or content-description rendered before it is elided.
const int _maxLabelLength = 80;

/// One node as a single line.
///
/// Coordinates come first because they are what the caller acts on. When
/// [screen] is given, a node whose centre falls outside it is flagged `o`:
/// scrolled-away nodes stay in the dump with off-screen bounds, and tapping one
/// would hit whatever is really at that point.
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
/// exactly one line. Real content-descriptions contain newlines — a Flutter
/// clock widget reports four lines in one label.
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
///
/// [limit] caps the output; the returned [truncated] count says how many were
/// dropped so the caller can say so rather than silently lying.
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

/// The full tree: every node, indented by depth.
///
/// Only worth asking for when the pruned listing missed something — a custom
/// view with no text, no description and no flags is invisible to the pruner
/// but visible here.
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

/// A leaf big enough to be the screen that reports no text at all.
///
/// The accessibility tree describes *widgets*; a surface that is painted rather
/// than composed of them — Flutter's `CustomPaint`, a canvas game, an embedded
/// terminal — appears as one empty `View` and its content is simply absent.
/// A dump that says "5 of 17 nodes" then reads like a successful dump rather
/// than a blind spot, and the honest answer is to take a screenshot.
///
/// Returns the offending node so the caller can point at it, or null.
///
/// Leaf and textless are the load-bearing conditions; the size threshold only
/// keeps ordinary empty spacers and dividers out. A false positive costs one
/// advisory line, so it is deliberately generous.
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
