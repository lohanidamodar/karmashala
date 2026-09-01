import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/idb_ui_parsing.dart';
import 'package:karmashala/src/features/devices/domain/device_input.dart';
import 'package:karmashala/src/features/devices/domain/ui_node.dart';

/// Shapes taken from idb's own documentation for
/// `idb ui describe-all --format complete`.
const _complete = '''
{
  "elements": [
    {
      "type": "Application",
      "label": "Settings",
      "identifier": "",
      "frame": {"x": 0, "y": 0, "width": 402, "height": 874},
      "enabled": true,
      "children": [
        {
          "type": "Button",
          "label": "General",
          "identifier": "com.apple.settings.general",
          "frame": {"x": 20, "y": 264, "width": 362, "height": 44},
          "enabled": true
        },
        {
          "type": "TextField",
          "label": "Name",
          "value": "iPhone",
          "identifier": "device-name",
          "frame": {"x": 20, "y": 320, "width": 362, "height": 44},
          "enabled": false
        }
      ]
    }
  ],
  "backend": "axbridge",
  "truncated": false,
  "screen": {"width": 402, "height": 874, "coordinate_space": "screen"}
}
''';

void main() {
  test('the screen is points, not pixels — a tap depends on it', () {
    // idb reports frames and accepts `idb ui tap X Y` in points; simctl
    // reports the backing store in pixels. On a 3x device, converting a tap
    // with the pixel size lands it three times too far down and right.
    final read = parseIdbUiRead(_complete);

    expect(read.screen, const DeviceScreenSize(width: 402, height: 874));
  });

  test('an element frame becomes edges', () {
    final read = parseIdbUiRead(_complete);
    final general = read.hierarchy.allNodes.firstWhere(
      (n) => n.resourceId == 'com.apple.settings.general',
    );

    expect(general.bounds, const UiBounds(left: 20, top: 264, right: 382, bottom: 308));
    expect(general.bounds!.center, (x: 201, y: 286));
  });

  test('the tree keeps its nesting', () {
    final read = parseIdbUiRead(_complete);

    expect(read.hierarchy.roots, hasLength(1));
    expect(read.hierarchy.roots.single.children, hasLength(2));
    expect(read.hierarchy.nodeCount, 3);
  });

  test('a field\'s value is its text, and its label survives beside it', () {
    // uiautomator conflates the two into `text`, and everything downstream
    // searches that — so the value wins, and the label stays reachable through
    // the same fallback `UiNode.label` already uses for Flutter semantics.
    final read = parseIdbUiRead(_complete);
    final field = read.hierarchy.allNodes.firstWhere(
      (n) => n.className == 'TextField',
    );

    expect(field.text, 'iPhone');
    expect(field.contentDescription, 'Name');
    expect(field.enabled, isFalse);
  });

  test('a label with no value is the text', () {
    final read = parseIdbUiRead(_complete);
    final general = read.hierarchy.allNodes.firstWhere(
      (n) => n.resourceId == 'com.apple.settings.general',
    );

    expect(general.text, 'General');
    expect(general.contentDescription, isEmpty);
  });

  test('clickability is derived from the type, because iOS has no such flag', () {
    // The accessibility tree says what a thing *is*, not what can be done to
    // it. The set is deliberately narrow: a false positive is an agent tapping
    // a label and reporting success.
    final read = parseIdbUiRead(_complete);
    final byType = {for (final n in read.hierarchy.allNodes) n.className: n};

    expect(byType['Button']!.clickable, isTrue);
    expect(byType['TextField']!.clickable, isTrue);
    expect(byType['Application']!.clickable, isFalse);
  });

  test('a switch is checkable and a secure field is a password', () {
    final read = parseIdbUiRead('''
      [{"type": "Switch", "label": "Wi-Fi"},
       {"type": "SecureTextField", "label": "Password"}]
    ''');
    final nodes = read.hierarchy.roots;

    expect(nodes.first.checkable, isTrue);
    expect(nodes.last.password, isTrue);
  });

  test('the legacy AX-prefixed format parses too', () {
    // A companion that predates `--format complete` answers in the old shape,
    // and idb only warns about it on stderr.
    final read = parseIdbUiRead('''
      [{"AXLabel": "General", "AXUniqueId": "gen", "type": "Button",
        "frame": {"x": 1, "y": 2, "width": 3, "height": 4}}]
    ''');

    expect(read.hierarchy.roots.single.text, 'General');
    expect(read.hierarchy.roots.single.resourceId, 'gen');
    expect(read.screen, isNull, reason: 'the old format carries no screen');
  });

  test('a single-element read is a bare object', () {
    // What `describe-point` returns when something is under the point.
    final read = parseIdbUiRead('{"type": "Button", "label": "OK"}');

    expect(read.hierarchy.roots.single.text, 'OK');
  });

  test('a read it cannot make sense of is "I could not see", not a crash', () {
    for (final input in ['', 'not json', 'null', '"a string"', '3']) {
      final read = parseIdbUiRead(input);
      expect(read.hierarchy.isEmpty, isTrue, reason: input);
      expect(read.screen, isNull, reason: input);
    }
  });

  test('a frame missing a number contributes no bounds rather than a wrong one', () {
    // Every tap by query is derived from bounds; a guessed rectangle taps the
    // wrong thing and reports success.
    final read = parseIdbUiRead('''
      [{"type": "Button", "label": "x", "frame": {"x": 1, "y": 2, "width": 3}}]
    ''');

    expect(read.hierarchy.roots.single.bounds, isNull);
  });

  test('a nonsense screen is no screen', () {
    expect(parseIdbUiRead('{"elements": [], "screen": {"width": 0, "height": 9}}').screen, isNull);
    expect(parseIdbUiRead('{"elements": [], "screen": "wat"}').screen, isNull);
  });
}
