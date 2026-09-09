import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/wda_ui_parsing.dart';
import 'package:karmashala_devices/src/domain/device_input.dart';
import 'package:karmashala_devices/src/domain/ui_node.dart';

/// Captured from a real `GET /source?format=json` against an iPhone 17 Pro on
/// iOS 26.4, trimmed. Note `isVisible` and `isEnabled` are the **strings**
/// "1"/"0", not JSON booleans, and every element carries both a `frame` string
/// and a structured `rect`.
const _source = '''
{
  "value": {
    "type": "Application",
    "label": " ",
    "frame": "{{0, 0}, {402, 874}}",
    "rect": {"x": 0, "y": 0, "width": 402, "height": 874},
    "isEnabled": "1",
    "isVisible": "1",
    "children": [
      {
        "type": "Icon",
        "label": "Fitness",
        "name": "Fitness",
        "frame": "{{28, 88}, {69, 91}}",
        "rect": {"x": 28, "y": 88, "width": 69, "height": 91},
        "isEnabled": "1",
        "isVisible": "1"
      },
      {
        "type": "Icon",
        "label": "Maps",
        "frame": "{{0, 0}, {0, 0}}",
        "rect": {"x": 0, "y": 0, "width": 0, "height": 0},
        "isEnabled": "1",
        "isVisible": "0"
      },
      {
        "type": "TextField",
        "label": "Name",
        "value": "iPhone",
        "rect": {"x": 20, "y": 320, "width": 362, "height": 44},
        "isEnabled": "0",
        "isVisible": "1"
      }
    ]
  },
  "sessionId": "abc"
}
''';

void main() {
  test('the application frame is the point-space screen', () {
    // Points, which is the space taps are in — not the 1206x2622 pixels
    // `simctl io enumerate` reports.
    final read = parseWdaUiRead(_source);

    expect(read.screen, const DeviceScreenSize(width: 402, height: 874));
  });

  test('the structured rect is preferred over the frame string', () {
    final read = parseWdaUiRead(_source);
    final fitness = read.hierarchy.allNodes.firstWhere(
      (n) => n.text == 'Fitness',
    );

    expect(fitness.bounds, const UiBounds(left: 28, top: 88, right: 97, bottom: 179));
  });

  test('an element with no rect falls back to the frame string', () {
    final read = parseWdaUiRead('''
      {"value": {"type": "Button", "label": "OK",
                 "frame": "{{10, 20}, {30, 40}}"}}
    ''');

    expect(
      read.hierarchy.roots.single.bounds,
      const UiBounds(left: 10, top: 20, right: 40, bottom: 60),
    );
  });

  test('an off-screen element is kept, with the zero frame it really has', () {
    // WDA reports every element in the tree, including the icons on other
    // home-screen pages. Those are genuinely not on screen and genuinely
    // cannot be tapped, which `UiBounds.isEmpty` already says.
    final read = parseWdaUiRead(_source);
    final maps = read.hierarchy.allNodes.firstWhere((n) => n.text == 'Maps');

    expect(maps.bounds!.isEmpty, isTrue);
  });

  test('"1" and "0" are booleans here, not truthy strings', () {
    // Reading these as Dart bools would make every element enabled.
    final read = parseWdaUiRead(_source);
    final field = read.hierarchy.allNodes.firstWhere(
      (n) => n.className == 'TextField',
    );

    expect(field.enabled, isFalse);
    expect(
      read.hierarchy.allNodes.firstWhere((n) => n.text == 'Fitness').enabled,
      isTrue,
    );
  });

  test('a field\'s value is its text, and the label survives beside it', () {
    final read = parseWdaUiRead(_source);
    final field = read.hierarchy.allNodes.firstWhere(
      (n) => n.className == 'TextField',
    );

    expect(field.text, 'iPhone');
    expect(field.contentDescription, 'Name');
  });

  test('clickability comes from the type, because iOS has no such flag', () {
    final read = parseWdaUiRead(_source);
    final byType = {for (final n in read.hierarchy.allNodes) n.className: n};

    expect(byType['TextField']!.clickable, isTrue);
    expect(byType['Application']!.clickable, isFalse);
    expect(byType['Icon']!.clickable, isFalse);
  });

  test('a read it cannot make sense of is "I could not see", not a crash', () {
    for (final input in ['', 'not json', 'null', '[1,2]', '{"value": 3}']) {
      expect(parseWdaUiRead(input).hierarchy.isEmpty, isTrue, reason: input);
    }
  });

  test('a malformed frame contributes no bounds rather than a wrong one', () {
    // Every tap by query is derived from these; a guessed rectangle taps the
    // wrong thing and reports success.
    final read = parseWdaUiRead(
      '{"value": {"type": "Button", "label": "x", "frame": "garbage"}}',
    );

    expect(read.hierarchy.roots.single.bounds, isNull);
  });
}
