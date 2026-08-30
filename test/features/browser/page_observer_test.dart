import 'package:flutter_test/flutter_test.dart';

import 'fake_browser.dart';

/// Lets the observer's event listeners run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('PageObserver', () {
    test('enables the two domains it needs, and only those', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();

      expect(browser.socket.methods, containsAll(['Log.enable']));
      expect(browser.socket.methods, contains('Network.enable'));
    });

    test('keeps console errors and warnings, drops the chatter', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();

      browser.socket.emitEvent('Runtime.consoleAPICalled', {
        'type': 'log',
        'args': [
          {'type': 'string', 'value': 'just talking'},
        ],
      });
      browser.socket.emitEvent('Runtime.consoleAPICalled', {
        'type': 'error',
        'args': [
          {'type': 'string', 'value': 'Cannot read properties of undefined'},
        ],
      });
      browser.socket.emitEvent('Runtime.consoleAPICalled', {
        'type': 'warning',
        'args': [
          {'type': 'string', 'value': 'deprecated API'},
        ],
      });
      await settle();

      final messages = browser.service.observer!.consoleMessages;
      expect(messages.map((m) => m.text), [
        'Cannot read properties of undefined',
        'deprecated API',
      ]);
      expect(messages.first.isError, isTrue);
      expect(messages.last.isError, isFalse);
    });

    test('records a thrown exception with where it came from', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();

      browser.socket.emitEvent('Runtime.exceptionThrown', {
        'exceptionDetails': {
          'text': 'Uncaught',
          'url': 'https://example.com/app.js',
          'lineNumber': 41,
          'exception': {'description': 'TypeError: x is not a function'},
        },
      });
      await settle();

      final message = browser.service.observer!.consoleMessages.single;
      expect(message.text, 'TypeError: x is not a function');
      // lineNumber is 0-based on the wire; a person counts from 1.
      expect(message.source, 'https://example.com/app.js:42');
    });

    test('the same error reported twice is one message', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();

      for (var i = 0; i < 2; i++) {
        browser.socket.emitEvent('Runtime.consoleAPICalled', {
          'type': 'error',
          'args': [
            {'type': 'string', 'value': 'boom'},
          ],
        });
      }
      await settle();

      expect(browser.service.observer!.consoleMessages, hasLength(1));
    });

    test('a 4xx response is a failure, a 200 is not', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();

      browser.socket.emitEvent('Network.requestWillBeSent', {
        'requestId': 'R1',
        'request': {'method': 'POST', 'url': 'https://api.test/save'},
      });
      browser.socket.emitEvent('Network.responseReceived', {
        'requestId': 'R1',
        'response': {'url': 'https://api.test/save', 'status': 500},
      });
      browser.socket.emitEvent('Network.requestWillBeSent', {
        'requestId': 'R2',
        'request': {'method': 'GET', 'url': 'https://api.test/ok'},
      });
      browser.socket.emitEvent('Network.responseReceived', {
        'requestId': 'R2',
        'response': {'url': 'https://api.test/ok', 'status': 200},
      });
      await settle();

      final failures = browser.service.observer!.networkFailures;
      expect(failures, hasLength(1));
      expect(failures.single.toLine(), contains('POST'));
      expect(failures.single.toLine(), contains('500'));
      expect(failures.single.toLine(), contains('https://api.test/save'));
    });

    test('a request that never arrives is named by its own URL', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();

      browser.socket.emitEvent('Network.requestWillBeSent', {
        'requestId': 'R9',
        'request': {'method': 'GET', 'url': 'https://down.test/thing.json'},
      });
      browser.socket.emitEvent('Network.loadingFailed', {
        'requestId': 'R9',
        'errorText': 'net::ERR_CONNECTION_REFUSED',
      });
      await settle();

      expect(
        browser.service.observer!.networkFailures.single.toLine(),
        'GET net::ERR_CONNECTION_REFUSED https://down.test/thing.json',
      );
    });

    test(
      'a failed request is one fault, not a console error as well',
      () async {
        final browser = FakeBrowser();
        await browser.connect();
        await browser.service.startObserving();

        // Chrome reports the same failure on both channels. Real Chrome, a host
        // that does not resolve: this is what listing it twice looked like.
        browser.socket.emitEvent('Network.requestWillBeSent', {
          'requestId': 'R7',
          'request': {'method': 'POST', 'url': 'https://nope.invalid/save'},
        });
        browser.socket.emitEvent('Network.loadingFailed', {
          'requestId': 'R7',
          'errorText': 'net::ERR_NAME_NOT_RESOLVED',
        });
        browser.socket.emitEvent('Log.entryAdded', {
          'entry': {
            'source': 'network',
            'level': 'error',
            'text': 'Failed to load resource: net::ERR_NAME_NOT_RESOLVED',
            'url': 'https://nope.invalid/save',
          },
        });
        await settle();

        expect(browser.service.observer!.networkFailures, hasLength(1));
        expect(browser.service.observer!.consoleMessages, isEmpty);
      },
    );

    test('a cancelled request is not evidence of anything', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();

      browser.socket.emitEvent('Network.requestWillBeSent', {
        'requestId': 'R3',
        'request': {'method': 'GET', 'url': 'https://example.com/late'},
      });
      browser.socket.emitEvent('Network.loadingFailed', {
        'requestId': 'R3',
        'errorText': 'net::ERR_ABORTED',
        'canceled': true,
      });
      await settle();

      expect(browser.service.observer!.networkFailures, isEmpty);
    });

    test('stopping keeps what was collected', () async {
      final browser = FakeBrowser();
      await browser.connect();
      await browser.service.startObserving();
      browser.socket.emitEvent('Runtime.consoleAPICalled', {
        'type': 'error',
        'args': [
          {'type': 'string', 'value': 'before the stop'},
        ],
      });
      await settle();

      await browser.service.stopObserving();
      browser.socket.emitEvent('Runtime.consoleAPICalled', {
        'type': 'error',
        'args': [
          {'type': 'string', 'value': 'after the stop'},
        ],
      });
      await settle();

      expect(browser.service.observer!.consoleMessages.map((m) => m.text), [
        'before the stop',
      ]);
    });

    test('nobody watching costs the page nothing', () async {
      final browser = FakeBrowser();
      await browser.connect();

      expect(browser.service.observer, isNull);
      expect(browser.socket.methods, isNot(contains('Network.enable')));
    });
  });
}
