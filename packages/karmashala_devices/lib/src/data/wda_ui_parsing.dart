import 'dart:convert';

import '../domain/device_input.dart';
import '../domain/ui_node.dart';

/// One `GET /source?format=json` read, mapped onto the tree the rest of the
/// app already speaks.
class WdaUiRead {
  const WdaUiRead({required this.hierarchy, this.screen});

  final UiHierarchy hierarchy;

  /// The application's own frame, in **points** — the space taps are in.
  final DeviceScreenSize? screen;
}

/// Element types WebDriverAgent reports that a person can actually act on. iOS
/// describes *what a thing is*, so the flag is derived from the type;
/// deliberately narrow, because a false positive is a tap on a label.
const Set<String> kWdaInteractiveTypes = {
  'Button',
  'Cell',
  'Link',
  'MenuItem',
  'PopUpButton',
  'RadioButton',
  'SearchField',
  'SecureTextField',
  'Slider',
  'Stepper',
  'Switch',
  'Tab',
  'TextField',
  'TextView',
  'Toggle',
};

/// Parses WebDriverAgent's `/source?format=json` document. Tolerant like
/// `parseUiAutomatorXml`: an unexpected document yields an empty read, because
/// evidence that failed to arrive is "I could not see", not a crash.
WdaUiRead parseWdaUiRead(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return WdaUiRead(hierarchy: UiHierarchy.empty);
  }
  if (decoded is! Map<String, Object?>) {
    return WdaUiRead(hierarchy: UiHierarchy.empty);
  }
  // WDA wraps every response in `{"value": …, "sessionId": …}`.
  final root = decoded['value'] is Map<String, Object?>
      ? decoded['value']! as Map<String, Object?>
      : decoded;

  final node = _nodeFrom(root, 0);
  // A JSON object is not automatically an element. Without this an unrecognised
  // response becomes a one-node tree that reads as "one blank thing on screen".
  if (node == null || !_looksLikeElement(node)) {
    return WdaUiRead(hierarchy: UiHierarchy.empty);
  }
  return WdaUiRead(
    hierarchy: UiHierarchy(roots: [node]),
    screen: _sizeOf(node.bounds),
  );
}

bool _looksLikeElement(UiNode node) =>
    node.className.isNotEmpty ||
    node.bounds != null ||
    node.children.isNotEmpty;

DeviceScreenSize? _sizeOf(UiBounds? bounds) {
  if (bounds == null || bounds.isEmpty) return null;
  return DeviceScreenSize(width: bounds.width, height: bounds.height);
}

UiNode? _nodeFrom(Object? raw, int index) {
  if (raw is! Map<String, Object?>) return null;

  final children = <UiNode>[];
  final rawChildren = raw['children'];
  if (rawChildren is List) {
    for (var i = 0; i < rawChildren.length; i++) {
      final child = _nodeFrom(rawChildren[i], i);
      if (child != null) children.add(child);
    }
  }

  final type = _string(raw['type']);
  final label = _string(raw['label']);
  final value = _string(raw['value']);

  return UiNode(
    index: index,
    // A field's *content* is its value and its label is what it is called;
    // uiautomator conflates them into `text`, so the value wins where there is
    // one.
    text: value.isNotEmpty ? value : label,
    // The label keeps its place as the content-description when the value took
    // `text` — the fallback `UiNode.label` already has for Flutter semantics.
    contentDescription: value.isNotEmpty ? label : '',
    resourceId: _string(raw['name']).isNotEmpty
        ? _string(raw['name'])
        : _string(raw['rawIdentifier']),
    className: type,
    bounds: _rectOf(raw['rect']) ?? _boundsOf(raw['frame']),
    // WDA writes these as the strings "1"/"0" rather than as JSON booleans.
    enabled: _flag(raw['isEnabled'], orElse: true),
    focused: _flag(raw['hasFocus']),
    clickable: kWdaInteractiveTypes.contains(type),
    checkable: type == 'Switch' || type == 'Toggle' || type == 'RadioButton',
    password: type == 'SecureTextField',
    children: children,
  );
}

/// WDA's structured `rect`, the same rectangle as `frame` without a string to
/// parse; `frame` is the fallback for a build that predates it. A zero rectangle
/// is kept: an element on another home-screen page really is there and really
/// cannot be tapped, which [UiBounds.isEmpty] already says.
UiBounds? _rectOf(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final x = raw['x'];
  final y = raw['y'];
  final width = raw['width'];
  final height = raw['height'];
  if (x is! num || y is! num || width is! num || height is! num) return null;
  return UiBounds(
    left: x.round(),
    top: y.round(),
    right: (x + width).round(),
    bottom: (y + height).round(),
  );
}

/// WDA writes a frame as the string `{{x, y}, {w, h}}`. Parsed strictly: every
/// tap by query comes from these, and a guess taps the wrong thing.
UiBounds? _boundsOf(Object? raw) {
  if (raw is! String) return null;
  final match = _framePattern.firstMatch(raw.trim());
  if (match == null) return null;
  final x = double.tryParse(match.group(1)!);
  final y = double.tryParse(match.group(2)!);
  final width = double.tryParse(match.group(3)!);
  final height = double.tryParse(match.group(4)!);
  if (x == null || y == null || width == null || height == null) return null;
  return UiBounds(
    left: x.round(),
    top: y.round(),
    right: (x + width).round(),
    bottom: (y + height).round(),
  );
}

final RegExp _framePattern = RegExp(
  r'^\{\{\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\}\s*,\s*\{\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\}\}$',
);

String _string(Object? raw) => raw is String ? raw : '';

bool _flag(Object? raw, {bool orElse = false}) => switch (raw) {
  bool value => value,
  '1' || 'true' => true,
  '0' || 'false' => false,
  _ => orElse,
};
