import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

import 'fake_browser.dart';

/// A connected browser with a sink installed, and the actions it reported.
Future<(FakeBrowser, List<BrowserAction>)> recording({
  Object? Function(PageScript kind, String expression)? replies,
}) async {
  final fake = FakeBrowser();
  fake.onEvaluate = (expression) {
    final kind = scriptKind(expression);
    if (kind != null) return replies?.call(kind, expression);
    if (expression == 'location.href') return 'https://example.com/app';
    if (expression == 'document.title') return 'Example';
    return null;
  };
  await fake.connect();
  final actions = <BrowserAction>[];
  fake.service.actionSink = actions.add;
  return (fake, actions);
}

void main() {
  group('the recorder seam', () {
    test('nothing is reported when nobody is listening', () async {
      final fake = FakeBrowser();
      await fake.connect();
      // No sink: the verbs still work, which is the property that matters —
      // recording must be something the service can be entirely without.
      await fake.service.navigate('https://example.com/next');
      expect(fake.service.actionSink, isNull);
    });

    test('a navigation is one step, naming where it went', () async {
      final (fake, actions) = await recording();
      await fake.service.navigate('https://example.com/next');
      expect(actions.single.verb, 'navigate');
      expect(actions.single.summary, 'Navigated to https://example.com/next');
      expect(actions.single.ok, isTrue);
    });

    test('a click reports the element it actually hit', () async {
      final (fake, actions) = await recording(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([describedElement()]),
          PageScript.clickTarget => clickReply(),
          _ => null,
        },
      );
      await fake.service.click(selector: '#go');
      expect(actions.single.verb, 'click');
      expect(actions.single.summary, contains('button'));
      expect(actions.single.detail, contains('in the viewport'));
    });

    test('a screenshot hands over its bytes, not a path', () async {
      final (fake, actions) = await recording();
      await fake.service.screenshot();
      expect(actions.single.verb, 'screenshot');
      expect(actions.single.png, isNotNull);
      expect(actions.single.png, isNotEmpty);
    });

    test('a capture carries both the crop and the prompt text', () async {
      final (fake, actions) = await recording(
        replies: (kind, _) => switch (kind) {
          PageScript.describeSelector => describeSelectorReply(),
          _ => null,
        },
      );
      await fake.service.capture('#go');
      final action = actions.single;
      expect(action.verb, 'capture');
      expect(action.png, isNotNull);
      expect(action.text, contains('#go'));
      expect(action.pageUrl, 'https://example.com/app');
    });

    test('a fill the page rejected is recorded as not ok', () async {
      final (fake, actions) = await recording(
        replies: (kind, _) => switch (kind) {
          PageScript.find => findReply([describedElement(tagName: 'input')]),
          PageScript.prepareField => {'ok': true, 'value': 'trunc'},
          PageScript.readField => {'ok': true, 'value': 'trunc'},
          _ => null,
        },
      );
      await fake.service.fill(selector: '#name', value: 'truncated');
      expect(actions.single.ok, isFalse);
      expect(actions.single.detail, contains('NOT what'));
    });

    test('a failure is recorded and still thrown', () async {
      final (fake, actions) = await recording(replies: (_, _) => null);
      await expectLater(
        fake.service.click(selector: '#missing'),
        throwsA(isA<BrowserException>()),
      );
      expect(actions.single.verb, 'click');
      expect(actions.single.ok, isFalse);
      expect(actions.single.detail, isNotNull);
    });

    test('a sink that throws does not break the browser call', () async {
      final fake = FakeBrowser();
      await fake.connect();
      fake.service.actionSink = (_) => throw StateError('recorder is broken');
      await fake.service.navigate('https://example.com/next');
      // Reached at all: the navigation was not taken down by the recorder.
      expect(fake.service.isConnected, isTrue);
    });
  });

  group('observing', () {
    test('starting an observation enables the two extra domains', () async {
      final fake = FakeBrowser();
      await fake.connect();
      await fake.service.startObserving();
      expect(fake.socket.methods, contains('Log.enable'));
      expect(fake.socket.methods, contains('Network.enable'));
      expect(fake.service.observer, isNotNull);
    });

    test('what was collected survives stopping the watch', () async {
      final fake = FakeBrowser();
      await fake.connect();
      await fake.service.startObserving();
      fake.socket.emitEvent('Runtime.consoleAPICalled', {
        'type': 'error',
        'args': [
          {'type': 'string', 'value': 'boom'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      await fake.service.stopObserving();
      expect(fake.service.observer?.consoleMessages.single.text, 'boom');
    });
  });
}
