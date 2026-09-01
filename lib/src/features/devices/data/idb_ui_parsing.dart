import 'dart:convert';

import '../domain/device_input.dart';
import '../domain/ui_node.dart';

/// One `idb ui describe-all --format complete` read, mapped onto the tree the
/// rest of the app already speaks.
///
/// [screen] is carried beside the tree because it is **not** the size
/// `simctl io enumerate` reports, and confusing the two taps the wrong place.
/// idb reports element frames — and accepts `idb ui tap X Y` — in **points**
/// (an iPhone 17 Pro reads 402x874), while `simctl` reports the backing store
/// in **pixels** (1206x2622). Using the pixel size to convert a tap on a 3x
/// device lands the touch three times too far down and to the right, off the
/// screen entirely.
class IdbUiRead {
  const IdbUiRead({required this.hierarchy, required this.screen});

  final UiHierarchy hierarchy;

  /// The bounds element frames are relative to, in points.
  final DeviceScreenSize? screen;
}

/// Element types idb reports that a person can actually act on.
///
/// The accessibility tree has no `clickable` attribute the way uiautomator
/// does — iOS describes *what a thing is*, not what can be done to it — so the
/// flag the rest of the app filters on is derived from the type. Kept
/// deliberately narrow: a false positive here is an agent tapping a label and
/// reporting success.
const Set<String> kIdbInteractiveTypes = {
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

/// Parses `idb ui describe-all --format complete --format nested`-shaped JSON.
///
/// Tolerant in the same way `parseUiAutomatorXml` is: a document that is not
/// what this build expects yields an empty read rather than throwing. A UI dump
/// is evidence for a decision, and evidence that failed to arrive is "I could
/// not see", not a crash.
IdbUiRead parseIdbUiRead(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return IdbUiRead(hierarchy: UiHierarchy.empty, screen: null);
  }

  // `complete` wraps the elements in a document; the older formats are a bare
  // array, or a bare object for a single-element read. All three are accepted
  // so a companion that predates format selection still parses.
  List<Object?> elements;
  DeviceScreenSize? screen;
  if (decoded is Map<String, Object?>) {
    final raw = decoded['elements'];
    if (raw is List) {
      elements = raw;
      screen = _screenOf(decoded['screen']);
    } else {
      elements = [decoded];
    }
  } else if (decoded is List) {
    elements = decoded;
  } else {
    return IdbUiRead(hierarchy: UiHierarchy.empty, screen: null);
  }

  final roots = <UiNode>[];
  for (final element in elements) {
    final node = _nodeFrom(element, 0);
    if (node != null) roots.add(node);
  }
  return IdbUiRead(
    hierarchy: UiHierarchy(roots: roots),
    screen: screen,
  );
}

DeviceScreenSize? _screenOf(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final width = raw['width'];
  final height = raw['height'];
  if (width is! num || height is! num) return null;
  if (width <= 0 || height <= 0) return null;
  return DeviceScreenSize(width: width.round(), height: height.round());
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

  // `complete` uses the clean names; the legacy format uses the AX-prefixed
  // ones. Both are read so one parser serves either companion.
  final type = _string(raw['type']);
  final label = _firstNonEmpty([
    _string(raw['label']),
    _string(raw['AXLabel']),
    _string(raw['title']),
  ]);
  final value = _firstNonEmpty([
    _string(raw['value']),
    _string(raw['AXValue']),
  ]);

  return UiNode(
    index: index,
    // A field's *content* is its value, and its label is what it is called.
    // uiautomator conflates them into `text`, and every caller downstream
    // searches that, so the value wins where there is one.
    text: value.isNotEmpty ? value : label,
    // The label survives as the content-description when the value took
    // `text`, which is what `UiNode.label`'s fallback exists for.
    contentDescription: value.isNotEmpty ? label : '',
    resourceId: _firstNonEmpty([
      _string(raw['identifier']),
      _string(raw['AXUniqueId']),
    ]),
    className: type,
    bounds: _boundsOf(raw['frame']),
    enabled: raw['enabled'] is bool ? raw['enabled']! as bool : true,
    focused: raw['focused'] is bool ? raw['focused']! as bool : false,
    clickable: kIdbInteractiveTypes.contains(type),
    checkable: type == 'Switch' || type == 'Toggle' || type == 'RadioButton',
    password: type == 'SecureTextField',
    children: children,
  );
}

/// idb's `frame` is `{x, y, width, height}`; [UiBounds] is edges.
UiBounds? _boundsOf(Object? raw) {
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

String _string(Object? raw) => raw is String ? raw : '';

String _firstNonEmpty(List<String> candidates) {
  for (final candidate in candidates) {
    if (candidate.trim().isNotEmpty) return candidate;
  }
  return '';
}
