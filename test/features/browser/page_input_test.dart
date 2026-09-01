import 'package:karmashala/src/features/browser/domain/browser_failure.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_browser.dart';

/// The service, connected, with a page that answers [replies] per script.
Future<FakeBrowser> connected({
  Object? Function(PageScript kind, String expression)? replies,
}) async {
  final fake = FakeBrowser();
  fake.onEvaluate = (expression) {
    final kind = scriptKind(expression);
    if (kind == null) return null;
    return replies?.call(kind, expression);
  };
  await fake.connect();
  return fake;
}

void main() {
  group('find', () {
    test('parses what the page reports', () async {
      final fake = await connected(
        replies: (kind, _) => kind == PageScript.find
            ? findReply([
                describedElement(),
                describedElement(
                  tagName: 'a',
                  selector: '#docs',
                  id: 'docs',
                  text: 'Docs',
                ),
              ], hidden: 3)
            : null,
      );
      final result = await fake.service.findElements(selector: '.thing');
      expect(result.total, 2);
      expect(result.hidden, 3);
      expect(result.elements.first.description, 'button#go');
      expect(result.elements.first.interactive, isTrue);
      expect(result.elements.last.text, 'Docs');
      expect(result.query, 'selector `.thing`');
    });

    test(
      'passes the selector, the text and the flags into the script',
      () async {
        final fake = await connected(
          replies: (kind, _) =>
              kind == PageScript.find ? findReply(const []) : null,
        );
        await fake.service.findElements(text: 'Sign in', exact: true, limit: 5);
        final script = fake.expressions.last;
        expect(script, contains('var NEEDLE = "Sign in"'));
        expect(script, contains('var EXACT = true'));
        expect(script, contains('var LIMIT = 5'));
      },
    );

    test('refuses a query with neither a selector nor text', () async {
      final fake = await connected();
      expect(
        () => fake.service.findElements(),
        failsWith(BrowserFailure.elementNotFound),
      );
    });

    test('reports a selector the page rejected, with the reason', () async {
      final fake = await connected(
        replies: (kind, _) => kind == PageScript.find
            ? {'error': 'invalid selector: bad token'}
            : null,
      );
      await expectLater(
        fake.service.findElements(selector: '<<<'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('bad token'),
          ),
        ),
      );
    });

    test('a text query names the text when nothing matches', () async {
      final fake = await connected(
        replies: (kind, _) =>
            kind == PageScript.find ? findReply(const []) : null,
      );
      await expectLater(
        fake.service.click(text: 'Sign in'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Nothing matches'), contains('"Sign in"')),
          ),
        ),
      );
    });
  });

  group('click', () {
    Object? standard(PageScript kind, String expression) => switch (kind) {
      PageScript.find => findReply([describedElement()]),
      PageScript.clickTarget => clickReply(x: 60, y: 35),
      _ => null,
    };

    test(
      'dispatches move, press and release at the point the page gave',
      () async {
        final fake = await connected(replies: standard);
        final result = await fake.service.click(selector: '#go');
        final events = fake.framesFor('Input.dispatchMouseEvent');
        expect(events.map((e) => e['type']), [
          'mouseMoved',
          'mousePressed',
          'mouseReleased',
        ]);
        expect(events.every((e) => e['x'] == 60 && e['y'] == 35), isTrue);
        expect(events[1]['button'], 'left');
        expect(events[1]['clickCount'], 1);
        expect(result.element.description, 'button#go');
        expect(result.x, 60);
      },
    );

    test('scrolls and hit-tests in the page, in one turn', () async {
      final fake = await connected(replies: standard);
      await fake.service.click(selector: '#go');
      final script = fake.expressions.last;
      expect(script, contains("behavior: 'instant'"));
      expect(script, contains('elementFromPoint'));
    });

    test('a double click sends two press/release pairs', () async {
      final fake = await connected(replies: standard);
      await fake.service.click(selector: '#go', clickCount: 2);
      final events = fake.framesFor('Input.dispatchMouseEvent');
      expect(events.map((e) => e['type']), [
        'mouseMoved',
        'mousePressed',
        'mouseReleased',
        'mousePressed',
        'mouseReleased',
      ]);
      expect(events.last['clickCount'], 2);
    });

    test(
      'names the element that covers the target, and clicks nothing',
      () async {
        final fake = await connected(
          replies: (kind, _) => switch (kind) {
            PageScript.find => findReply([describedElement()]),
            PageScript.clickTarget => {
              'ok': false,
              'reason': 'covered',
              'element': describedElement(),
              'blocker': describedElement(
                tagName: 'div',
                selector: '#cookie-banner',
                id: 'cookie-banner',
                text: 'We use cookies',
              ),
            },
            _ => null,
          },
        );
        await expectLater(
          fake.service.click(selector: '#go'),
          throwsA(
            isA<BrowserException>().having(
              (e) => e.message,
              'message',
              allOf(contains('div#cookie-banner'), contains('covering')),
            ),
          ),
        );
        expect(fake.framesFor('Input.dispatchMouseEvent'), isEmpty);
      },
    );

    test(
      'says so when the element is still off screen after scrolling',
      () async {
        final fake = await connected(
          replies: (kind, _) => switch (kind) {
            PageScript.find => findReply([describedElement()]),
            PageScript.clickTarget => {
              'ok': false,
              'reason': 'offscreen',
              'element': describedElement(),
            },
            _ => null,
          },
        );
        await expectLater(
          fake.service.click(selector: '#go'),
          throwsA(
            isA<BrowserException>().having(
              (e) => e.message,
              'message',
              contains('outside the viewport'),
            ),
          ),
        );
      },
    );

    test(
      'says so when the element vanished between finding and clicking',
      () async {
        final fake = await connected(
          replies: (kind, _) => switch (kind) {
            PageScript.find => findReply([describedElement()]),
            PageScript.clickTarget => {'ok': false, 'reason': 'gone'},
            _ => null,
          },
        );
        await expectLater(
          fake.service.click(selector: '#go'),
          throwsA(
            isA<BrowserException>().having(
              (e) => e.message,
              'message',
              contains('disappeared'),
            ),
          ),
        );
      },
    );

    test('a selector matching several elements is always refused', () async {
      final fake = await connected(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([
            describedElement(selector: '.row:nth-of-type(1)', id: null),
            describedElement(selector: '.row:nth-of-type(2)', id: null),
          ]),
          PageScript.clickTarget => clickReply(),
          _ => null,
        },
      );
      await expectLater(
        fake.service.click(selector: '.row'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            allOf(contains('matches 2 elements'), contains('[1] ')),
          ),
        ),
      );
      expect(fake.framesFor('Input.dispatchMouseEvent'), isEmpty);
    });

    test(
      'two identical labels are ambiguous rather than a coin toss',
      () async {
        final fake = await connected(
          replies: (kind, _) => switch (kind) {
            PageScript.find => findReply([
              describedElement(selector: '#a', id: 'a', text: 'Delete'),
              describedElement(selector: '#b', id: 'b', text: 'Delete'),
            ]),
            PageScript.clickTarget => clickReply(),
            _ => null,
          },
        );
        expect(
          () => fake.service.click(text: 'Delete'),
          failsWith(BrowserFailure.elementNotFound),
        );
      },
    );

    test('a best match that is clearly better than the rest is used', () async {
      final fake = await connected(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([
            describedElement(selector: '#save', id: 'save', text: 'Save'),
            describedElement(
              tagName: 'div',
              selector: '#hint',
              id: 'hint',
              text: 'Save your work first',
              interactive: false,
            ),
          ]),
          PageScript.clickTarget => clickReply(
            element: describedElement(
              selector: '#save',
              id: 'save',
              text: 'Save',
            ),
          ),
          _ => null,
        },
      );
      final result = await fake.service.click(text: 'Save');
      expect(result.element.elementId, 'save');
      expect(result.candidates, 2);
    });

    test('index chooses among several matches', () async {
      final fake = await connected(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([
            describedElement(selector: '#a', id: 'a'),
            describedElement(selector: '#b', id: 'b'),
          ]),
          PageScript.clickTarget => clickReply(
            element: describedElement(selector: '#b', id: 'b'),
          ),
          _ => null,
        },
      );
      final result = await fake.service.click(text: 'Go', index: 1);
      expect(result.element.elementId, 'b');
      expect(fake.expressions.any((e) => e.contains('"#b"')), isTrue);
    });

    test('an index past the end is an error, not a wrong click', () async {
      final fake = await connected(
        replies: (kind, _) => kind == PageScript.find
            ? findReply([describedElement()], total: 1)
            : null,
      );
      await expectLater(
        fake.service.click(selector: '.row', index: 3),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('out of range'),
          ),
        ),
      );
    });

    test(
      'an element with no derivable selector is refused, not guessed at',
      () async {
        final fake = await connected(
          replies: (kind, _) => kind == PageScript.find
              ? findReply([describedElement(selector: null, id: null)])
              : null,
        );
        await expectLater(
          fake.service.click(text: 'Go'),
          throwsA(
            isA<BrowserException>().having(
              (e) => e.message,
              'message',
              contains('shadow root'),
            ),
          ),
        );
      },
    );

    test('a match that is only hidden explains that', () async {
      final fake = await connected(
        replies: (kind, _) => kind == PageScript.find
            ? findReply(const [], total: 0, hidden: 2)
            : null,
      );
      await expectLater(
        fake.service.click(selector: '#go'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('hidden'),
          ),
        ),
      );
    });
  });

  group('type', () {
    test(
      'sends one keyDown/keyUp pair per character, carrying the text',
      () async {
        final fake = await connected();
        await fake.service.type('hi');
        final keys = fake.framesFor('Input.dispatchKeyEvent');
        expect(keys.map((k) => k['type']), [
          'keyDown',
          'keyUp',
          'keyDown',
          'keyUp',
        ]);
        expect(keys[0]['text'], 'h');
        expect(keys[2]['text'], 'i');
        expect(keys[1]['text'], isNull, reason: 'keyUp inserts nothing');
      },
    );

    test('a newline in the text is the Enter key, not a character', () async {
      final fake = await connected();
      await fake.service.type('\n');
      final keys = fake.framesFor('Input.dispatchKeyEvent');
      expect(keys.first['key'], 'Enter');
      expect(keys.first['windowsVirtualKeyCode'], 13);
    });

    test('clicks the field first when one is named', () async {
      final fake = await connected(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([describedElement()]),
          PageScript.clickTarget => clickReply(),
          PageScript.readField => 'hi',
          _ => null,
        },
      );
      final result = await fake.service.type('hi', selector: '#go');
      expect(fake.framesFor('Input.dispatchMouseEvent'), isNotEmpty);
      expect(result.value, 'hi');
      expect(result.matches, isTrue);
    });

    test('submit presses Enter after the text', () async {
      final fake = await connected();
      await fake.service.type('a', submit: true);
      final keys = fake.framesFor('Input.dispatchKeyEvent');
      expect(keys.last['key'], 'Enter');
      expect(keys.first['text'], 'a');
    });

    test('asks the page what has focus when no field was named', () async {
      final fake = await connected(
        replies: (kind, _) => kind == PageScript.activeElement
            ? describedElement(
                tagName: 'input',
                selector: '#email',
                id: 'email',
              )
            : kind == PageScript.readField
            ? 'typed'
            : null,
      );
      final result = await fake.service.type('typed');
      expect(result.element?.elementId, 'email');
      expect(result.value, 'typed');
    });
  });

  group('fill', () {
    Object? editable(PageScript kind, String expression) => switch (kind) {
      PageScript.find => findReply([
        describedElement(tagName: 'input', selector: '#email', id: 'email'),
      ]),
      PageScript.prepareField => {
        'ok': true,
        'mode': 'text',
        'element': describedElement(
          tagName: 'input',
          selector: '#email',
          id: 'email',
        ),
        'had': 'old',
        'focused': true,
      },
      PageScript.readField => 'ada@example.com',
      _ => null,
    };

    test('selects the old value and inserts the new one', () async {
      final fake = await connected(replies: editable);
      final result = await fake.service.fill(
        selector: '#email',
        value: 'ada@example.com',
      );
      expect(
        fake.framesFor('Input.insertText').single['text'],
        'ada@example.com',
      );
      expect(result.value, 'ada@example.com');
      expect(result.matches, isTrue);
      final prepare = fake.expressions.firstWhere(
        (e) => e.contains('uneditableInput'),
      );
      expect(prepare, contains('el.select()'));
      expect(prepare, contains('"ada@example.com"'));
    });

    test(
      'an empty value deletes the selection instead of inserting nothing',
      () async {
        final fake = await connected(
          replies: (kind, e) =>
              kind == PageScript.readField ? '' : editable(kind, e),
        );
        final result = await fake.service.fill(selector: '#email', value: '');
        expect(fake.framesFor('Input.insertText'), isEmpty);
        expect(fake.framesFor('Input.dispatchKeyEvent').first['key'], 'Delete');
        expect(result.value, '');
      },
    );

    test('reports a value the page did not keep', () async {
      final fake = await connected(
        replies: (kind, e) =>
            kind == PageScript.readField ? 'ada@' : editable(kind, e),
      );
      final result = await fake.service.fill(
        selector: '#email',
        value: 'ada@example.com',
      );
      expect(result.matches, isFalse);
      expect(result.value, 'ada@');
    });

    test('a select is set in the page, with no keystrokes at all', () async {
      final fake = await connected(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([
            describedElement(
              tagName: 'select',
              selector: '#colour',
              id: 'colour',
            ),
          ]),
          PageScript.prepareField => {
            'ok': true,
            'mode': 'select',
            'element': describedElement(
              tagName: 'select',
              selector: '#colour',
              id: 'colour',
            ),
            'value': 'g',
          },
          _ => null,
        },
      );
      final result = await fake.service.fill(
        selector: '#colour',
        value: 'Green',
      );
      expect(result.value, 'g');
      expect(fake.framesFor('Input.insertText'), isEmpty);
      expect(fake.framesFor('Input.dispatchKeyEvent'), isEmpty);
    });

    test('lists the options when none matches', () async {
      final fake = await connected(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([
            describedElement(tagName: 'select', selector: '#colour'),
          ]),
          PageScript.prepareField => {
            'ok': false,
            'reason': 'nooption',
            'element': describedElement(tagName: 'select'),
            'options': ['Red', 'Green'],
          },
          _ => null,
        },
      );
      await expectLater(
        fake.service.fill(selector: '#colour', value: 'Blue'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('Red, Green'),
          ),
        ),
      );
    });

    for (final (reason, extra, expected) in [
      ('noteditable', <String, Object?>{}, 'not a text field'),
      ('disabled', <String, Object?>{}, 'is disabled'),
      ('readonly', <String, Object?>{}, 'read-only'),
      ('notext', {'type': 'checkbox'}, 'holds no text'),
    ]) {
      test('refuses a $reason field and says why', () async {
        final fake = await connected(
          replies: (kind, _) => switch (kind) {
            PageScript.find => findReply([describedElement()]),
            PageScript.prepareField => {
              'ok': false,
              'reason': reason,
              'element': describedElement(),
              ...extra,
            },
            _ => null,
          },
        );
        await expectLater(
          fake.service.fill(selector: '#go', value: 'x'),
          throwsA(
            isA<BrowserException>().having(
              (e) => e.message,
              'message',
              contains(expected),
            ),
          ),
        );
        expect(fake.framesFor('Input.insertText'), isEmpty);
      });
    }
  });

  group('keys and scrolling', () {
    test('a named key sends a matching keyDown and keyUp', () async {
      final fake = await connected();
      await fake.service.pressKey('ArrowDown');
      final keys = fake.framesFor('Input.dispatchKeyEvent');
      expect(keys.map((k) => k['key']), ['ArrowDown', 'ArrowDown']);
      expect(keys.first['code'], 'ArrowDown');
      expect(keys.first['windowsVirtualKeyCode'], 40);
    });

    test('an unknown key lists the ones that exist', () async {
      final fake = await connected();
      await expectLater(
        fake.service.pressKey('f13'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            allOf(contains('f13'), contains('arrowDown')),
          ),
        ),
      );
    });

    test('scrolling dispatches a wheel event', () async {
      final fake = await connected(
        replies: (kind, expression) => expression.contains('innerWidth / 2')
            ? {'x': 400.0, 'y': 300.0}
            : null,
      );
      await fake.service.scrollBy(dy: 500);
      final event = fake.framesFor('Input.dispatchMouseEvent').single;
      expect(event['type'], 'mouseWheel');
      expect(event['deltaY'], 500);
    });
  });

  group('with no session', () {
    test('every input verb fails the future, never synchronously', () async {
      // The bug this guards against: a verb that threw before a Future
      // existed, so `service.click(...).catchError(...)` blew up at the call
      // site instead of taking the error path. Loop 35 fixed it once; the MCP
      // wiring calls every one of these, so it is asserted for every verb.
      final fake = FakeBrowser();
      for (final call in <Future<Object?> Function()>[
        () => fake.service.findElements(selector: '#go'),
        () => fake.service.click(selector: '#go'),
        () => fake.service.type('x'),
        () => fake.service.fill(selector: '#go', value: 'x'),
        () => fake.service.pressKey('enter'),
        () => fake.service.scrollBy(dy: 1),
        () => fake.service.currentUrl(),
      ]) {
        Future<Object?>? pending;
        expect(() => pending = call(), returnsNormally);
        await expectLater(pending, failsWith(BrowserFailure.notRunning));
      }
    });
  });
}
