import 'package:chitragupta/src/features/browser/domain/picked_element.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PickedElement.fromJson', () {
    test('reads a full picker payload', () {
      final element = PickedElement.fromJson(const {
        'ok': true,
        'selector': '#hero > button:nth-of-type(2)',
        'tagName': 'button',
        'id': 'cta',
        'classNames': ['primary', 'lg'],
        'clientX': 120.5,
        'clientY': 240.0,
        'box': {'x': 10, 'y': 2500, 'width': 100, 'height': 40},
        'url': 'https://example.com',
        'title': 'Example',
      });
      expect(element.selector, '#hero > button:nth-of-type(2)');
      expect(element.tagName, 'button');
      expect(element.elementId, 'cta');
      expect(element.classNames, ['primary', 'lg']);
      expect(element.clientX, 120.5);
      expect(element.box.y, 2500);
      expect(element.url, 'https://example.com');
    });

    test('a null selector survives, because it drives the fallback', () {
      final element = PickedElement.fromJson(const {
        'ok': true,
        'selector': null,
        'tagName': 'div',
        'clientX': 5.0,
        'clientY': 6.0,
        'box': {'x': 0, 'y': 0, 'width': 1, 'height': 1},
      });
      expect(element.selector, isNull);
      expect(element.clientX, 5.0);
    });

    test('tolerates a payload missing everything optional', () {
      final element = PickedElement.fromJson(const {});
      expect(element.tagName, 'unknown');
      expect(element.classNames, isEmpty);
      expect(element.box.isEmpty, isTrue);
      expect(element.url, '');
    });
  });

  group('parsePickPayload', () {
    test('ok true means an element was selected', () {
      final outcome = parsePickPayload(const {
        'ok': true,
        'tagName': 'span',
        'box': {'x': 0, 'y': 0, 'width': 2, 'height': 2},
      });
      expect(outcome, isA<PickSelected>());
      expect((outcome as PickSelected).element.tagName, 'span');
    });

    test('anything else means the user backed out', () {
      expect(
        parsePickPayload(const {'ok': false, 'cancelled': true}),
        isA<PickCancelled>(),
      );
      expect(parsePickPayload(const {}), isA<PickCancelled>());
    });
  });
}
