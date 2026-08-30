import 'package:chitragupta/src/features/browser/domain/found_element.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> json({
    Object? selector = '#go',
    String text = 'Go',
    bool visible = true,
    bool interactive = true,
    bool inViewport = true,
    bool disabled = false,
  }) => {
    'selector': selector,
    'tagName': 'button',
    'id': 'go',
    'classNames': ['primary', 'large', 'rounded'],
    'text': text,
    'visible': visible,
    'interactive': interactive,
    'inViewport': inViewport,
    'disabled': disabled,
    'centerX': 60.0,
    'centerY': 35.0,
    'box': {'x': 10, 'y': 20, 'width': 100, 'height': 30},
  };

  test('parses the page description', () {
    final element = FoundElement.fromJson(json());
    expect(element.selector, '#go');
    expect(element.tagName, 'button');
    expect(element.classNames, ['primary', 'large', 'rounded']);
    expect(element.box.width, 100);
    expect(element.centerX, 60);
  });

  test('a missing field never breaks the parse', () {
    final element = FoundElement.fromJson(const {});
    expect(element.tagName, 'unknown');
    expect(element.selector, isNull);
    expect(element.visible, isTrue);
    expect(element.interactive, isFalse);
  });

  test('the description is a short CSS-ish label', () {
    expect(
      FoundElement.fromJson(json()).description,
      'button#go.primary.large',
    );
  });

  test('a listing line carries text, selector, box and the flags', () {
    final line = FoundElement.fromJson(
      json(interactive: true, disabled: true),
    ).toListing();
    expect(line, contains('button#go'));
    expect(line, contains('"Go"'));
    expect(line, contains('`#go`'));
    expect(line, contains('100x30 at (10, 20)'));
    expect(line, contains('[interactive, disabled]'));
  });

  test(
    'an element with no selector says so rather than looking addressable',
    () {
      final line = FoundElement.fromJson(json(selector: null)).toListing();
      expect(line, contains('(no selector)'));
    },
  );

  test('long text is squashed onto one line', () {
    final line = FoundElement.fromJson(
      json(text: 'a very long label\n  spread over lines ${'x' * 200}'),
    ).toListing();
    expect(line.split('\n'), hasLength(1));
    expect(line, contains('…'));
  });

  test('a fill that was not kept is not reported as a match', () {
    const kept = TypeResult(element: null, text: 'abc', value: 'abc');
    const truncated = TypeResult(element: null, text: 'abcdef', value: 'abcd');
    const unreadable = TypeResult(element: null, text: 'abc', value: null);
    expect(kept.matches, isTrue);
    expect(truncated.matches, isFalse);
    expect(unreadable.matches, isTrue, reason: 'nothing to contradict');
  });
}
