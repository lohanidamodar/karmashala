import 'dart:convert';
import 'dart:typed_data';

import 'package:chitragupta/src/features/browser/domain/element_capture.dart';
import 'package:flutter_test/flutter_test.dart';

ElementCapture buildCapture({
  Map<String, String>? styles,
  Uint8List? screenshot,
  String outerHtml = '<button id="go" class="primary">Go</button>',
}) => ElementCapture(
  selector: '#go',
  tagName: 'button',
  elementId: 'go',
  classNames: const ['primary', 'large'],
  outerHtml: outerHtml,
  computedStyles:
      styles ??
      const {
        'display': 'inline-flex',
        'color': 'rgb(255, 255, 255)',
        'background-color': 'rgb(37, 99, 235)',
        'box-shadow': 'none',
        'letter-spacing': 'normal',
        'align-items': '',
        '-webkit-font-smoothing': 'auto',
      },
  box: const ElementBox(x: 10, y: 20, width: 120, height: 40),
  pageUrl: 'https://example.com/pricing',
  pageTitle: 'Pricing',
  capturedAt: DateTime.utc(2026, 8, 30, 12),
  screenshotPng: screenshot,
);

void main() {
  group('ElementBox', () {
    test('parses numbers, strings and missing keys', () {
      final box = ElementBox.fromJson({'x': 1, 'y': '2.5', 'width': 3.5});
      expect(box.x, 1);
      expect(box.y, 2.5);
      expect(box.width, 3.5);
      expect(box.height, 0);
    });

    test('is empty when it has no area', () {
      expect(
        const ElementBox(x: 0, y: 0, width: 0, height: 10).isEmpty,
        isTrue,
      );
      expect(
        const ElementBox(x: 0, y: 0, width: 5, height: 10).isEmpty,
        isFalse,
      );
    });

    test('reads as size and position', () {
      expect(
        const ElementBox(x: 10.4, y: 20.6, width: 100, height: 50).toString(),
        '100x50 at (10, 21)',
      );
    });
  });

  group('ElementCapture', () {
    test('describes itself as a CSS-ish label', () {
      expect(buildCapture().description, 'button#go.primary.large');
    });

    test('promptStyles keeps meaningful properties in a fixed order', () {
      final styles = buildCapture().promptStyles;
      expect(styles.keys.toList(), ['display', 'color', 'background-color']);
    });

    test('promptStyles drops empty, none and normal values', () {
      final styles = buildCapture().promptStyles;
      expect(styles.containsKey('box-shadow'), isFalse);
      expect(styles.containsKey('letter-spacing'), isFalse);
      expect(styles.containsKey('align-items'), isFalse);
    });

    test('promptStyles ignores properties not on the curated list', () {
      expect(
        buildCapture().promptStyles.containsKey('-webkit-font-smoothing'),
        isFalse,
      );
    });

    test('prompt text carries the element, the page and the markup', () {
      final text = buildCapture(
        screenshot: Uint8List.fromList(List.filled(64, 1)),
      ).toPromptText();
      expect(text, contains('button#go.primary.large'));
      expect(text, contains('https://example.com/pricing'));
      expect(text, contains('Selector: `#go`'));
      expect(text, contains('120x40 at (10, 20)'));
      expect(text, contains('<button id="go" class="primary">Go</button>'));
      expect(text, contains('display: inline-flex;'));
      expect(text, contains('64 bytes of PNG'));
    });

    test('prompt text says so when there is no screenshot', () {
      expect(buildCapture().toPromptText(), contains('no rendered area'));
    });

    test('prompt text truncates very long markup', () {
      final text = buildCapture(
        outerHtml: '<div>${'x' * 5000}</div>',
      ).toPromptText(maxHtmlChars: 100);
      expect(text, contains('<!-- truncated -->'));
      expect(text.length, lessThan(2000));
    });

    test('json form is complete and base64s the screenshot', () {
      final json = buildCapture(
        screenshot: Uint8List.fromList([1, 2, 3]),
      ).toJson();
      expect(json['selector'], '#go');
      expect(json['tagName'], 'button');
      expect(json['id'], 'go');
      expect(json['classNames'], ['primary', 'large']);
      expect(json['pageUrl'], 'https://example.com/pricing');
      expect(json['capturedAt'], '2026-08-30T12:00:00.000Z');
      expect(json['box'], {
        'x': 10.0,
        'y': 20.0,
        'width': 120.0,
        'height': 40.0,
      });
      expect(base64Decode(json['screenshotPngBase64']! as String), [1, 2, 3]);
      expect(jsonEncode(json), isNotEmpty);
    });

    test('json form can leave the screenshot out', () {
      final json = buildCapture(
        screenshot: Uint8List.fromList([1]),
      ).toJson(includeScreenshot: false);
      expect(json.containsKey('screenshotPngBase64'), isFalse);
    });
  });
}
