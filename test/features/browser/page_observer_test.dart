import 'package:chitragupta/src/features/browser/data/cdp_connection.dart';
import 'package:chitragupta/src/features/browser/data/cdp_page.dart';
import 'package:chitragupta/src/features/browser/data/page_observer.dart';
import 'package:chitragupta/src/features/browser/domain/browser_target.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_cdp_socket.dart';

const _target = BrowserTarget(
  id: 'T1',
  type: 'page',
  title: 'Example',
  url: 'https://example.com',
  webSocketDebuggerUrl: 'ws://127.0.0.1:9222/devtools/page/T1',
);

({CdpPage page, FakeCdpSocket socket}) buildPage() {
  final socket = FakeCdpSocket()
    ..responder = (_, _) => const <String, Object?>{};
  return (
    page: CdpPage(connection: CdpConnection(socket), target: _target),
    socket: socket,
  );
}

/// Lets the broadcast stream deliver what was emitted.
Future<void> settle() => Future<void>.delayed(Duration.zero);

Map<String, Object?> consoleApi(String type, List<String> args) => {
  'type': type,
  'args': [
    for (final arg in args) {'type': 'string', 'value': arg},
  ],
};

void main() {
  group('console', () {
    test('keeps console.error and console.warn, drops the rest', () async {
      final fixture = buildPage();
      final observer = PageObserver();
      await observer.watch(fixture.page);

      fixture.socket
        ..emitEvent('Runtime.consoleAPICalled', consoleApi('error', ['boom']))
        ..emitEvent('Runtime.consoleAPICalled', consoleApi('warning', ['hm']))
        ..emitEvent('Runtime.consoleAPICalled', consoleApi('log', ['noise']))
        ..emitEvent('Runtime.consoleAPICalled', consoleApi('info', ['noise']));
      await settle();

      expect(observer.consoleMessages.map((m) => m.text), ['boom', 'hm']);
      expect(observer.consoleMessages.first.isError, isTrue);
      await observer.stop();
    });

    test('enables the two domains the page does not already have', () async {
      final fixture = buildPage();
      await PageObserver().watch(fixture.page);
      expect(fixture.socket.methods, contains('Log.enable'));
      expect(fixture.socket.methods, contains('Network.enable'));
    });

    test('an uncaught exception is an error, with its source', () async {
      final fixture = buildPage();
      final observer = PageObserver();
      await observer.watch(fixture.page);

      fixture.socket.emitEvent('Runtime.exceptionThrown', {
        'exceptionDetails': {
          'text': 'Uncaught',
          'url': 'https://example.com/app.js',
          'lineNumber': 41,
          'exception': {'description': 'TypeError: x is not a function'},
        },
      });
      await settle();

      final message = observer.consoleMessages.single;
      expect(message.text, 'TypeError: x is not a function');
      // Chrome counts lines from zero; a person reading a stack does not.
      expect(message.source, 'https://example.com/app.js:42');
      await observer.stop();
    });

    test(
      'a Log entry that repeats a console call is not counted twice',
      () async {
        final fixture = buildPage();
        final observer = PageObserver();
        await observer.watch(fixture.page);

        fixture.socket
          ..emitEvent('Runtime.consoleAPICalled', consoleApi('error', ['same']))
          ..emitEvent('Log.entryAdded', {
            'entry': {'level': 'error', 'text': 'same'},
          });
        await settle();

        expect(observer.consoleMessages, hasLength(1));
        await observer.stop();
      },
    );

    test('the first errors are kept, not the last', () async {
      final fixture = buildPage();
      final observer = PageObserver(limit: 2);
      await observer.watch(fixture.page);

      for (final text in ['first', 'second', 'third']) {
        fixture.socket.emitEvent(
          'Runtime.consoleAPICalled',
          consoleApi('error', [text]),
        );
      }
      await settle();

      expect(observer.consoleMessages.map((m) => m.text), ['first', 'second']);
      expect(observer.consoleDropped, 1);
      await observer.stop();
    });
  });

  group('network', () {
    test('a >= 400 response is a failure, named by method and url', () async {
      final fixture = buildPage();
      final observer = PageObserver();
      await observer.watch(fixture.page);

      fixture.socket
        ..emitEvent('Network.requestWillBeSent', {
          'requestId': 'R1',
          'request': {'method': 'GET', 'url': 'https://example.com/missing'},
        })
        ..emitEvent('Network.responseReceived', {
          'requestId': 'R1',
          'response': {'url': 'https://example.com/missing', 'status': 404},
        });
      await settle();

      expect(
        observer.networkFailures.single.toLine(),
        'GET 404 https://example.com/missing',
      );
      await observer.stop();
    });

    test('a 200 is not evidence', () async {
      final fixture = buildPage();
      final observer = PageObserver();
      await observer.watch(fixture.page);

      fixture.socket.emitEvent('Network.responseReceived', {
        'requestId': 'R1',
        'response': {'url': 'https://example.com/ok', 'status': 200},
      });
      await settle();

      expect(observer.networkFailures, isEmpty);
      await observer.stop();
    });

    test('a request that never arrived carries Chrome\'s own reason', () async {
      final fixture = buildPage();
      final observer = PageObserver();
      await observer.watch(fixture.page);

      fixture.socket
        ..emitEvent('Network.requestWillBeSent', {
          'requestId': 'R2',
          'request': {'method': 'POST', 'url': 'https://nowhere.invalid/api'},
        })
        ..emitEvent('Network.loadingFailed', {
          'requestId': 'R2',
          'errorText': 'net::ERR_NAME_NOT_RESOLVED',
        });
      await settle();

      expect(
        observer.networkFailures.single.toLine(),
        'POST net::ERR_NAME_NOT_RESOLVED https://nowhere.invalid/api',
      );
      await observer.stop();
    });

    test('a cancelled request is not a failure', () async {
      final fixture = buildPage();
      final observer = PageObserver();
      await observer.watch(fixture.page);

      fixture.socket
        ..emitEvent('Network.requestWillBeSent', {
          'requestId': 'R3',
          'request': {'method': 'GET', 'url': 'https://example.com/slow'},
        })
        ..emitEvent('Network.loadingFailed', {
          'requestId': 'R3',
          'errorText': 'net::ERR_ABORTED',
          'canceled': true,
        });
      await settle();

      expect(observer.networkFailures, isEmpty);
      await observer.stop();
    });
  });

  test('watching a second page keeps what the first one reported', () async {
    final first = buildPage();
    final second = buildPage();
    final observer = PageObserver();
    await observer.watch(first.page);

    first.socket.emitEvent(
      'Runtime.consoleAPICalled',
      consoleApi('error', ['before the switch']),
    );
    await settle();

    await observer.watch(second.page);
    second.socket.emitEvent(
      'Runtime.consoleAPICalled',
      consoleApi('error', ['after the switch']),
    );
    await settle();

    expect(observer.consoleMessages.map((m) => m.text), [
      'before the switch',
      'after the switch',
    ]);
    await observer.stop();
  });

  test('stopping keeps what was collected but hears nothing new', () async {
    final fixture = buildPage();
    final observer = PageObserver();
    await observer.watch(fixture.page);

    fixture.socket.emitEvent(
      'Runtime.consoleAPICalled',
      consoleApi('error', ['kept']),
    );
    await settle();
    await observer.stop();

    fixture.socket.emitEvent(
      'Runtime.consoleAPICalled',
      consoleApi('error', ['ignored']),
    );
    await settle();

    expect(observer.consoleMessages.map((m) => m.text), ['kept']);
  });
}
