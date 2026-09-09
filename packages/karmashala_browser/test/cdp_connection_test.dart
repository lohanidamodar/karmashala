import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

import 'fake_cdp_socket.dart';

Matcher failsWith(BrowserFailure failure) => throwsA(
  isA<BrowserException>().having((e) => e.failure, 'failure', failure),
);

void main() {
  group('id correlation', () {
    test('assigns increasing ids and matches replies to requests', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      final first = connection.send('A');
      final second = connection.send('B');

      expect(socket.sentFrames.map((f) => f['id']), [1, 2]);
      // Answer out of order: correlation must be by id, not arrival order.
      socket.respond(2, {'who': 'B'});
      socket.respond(1, {'who': 'A'});

      expect(await first, {'who': 'A'});
      expect(await second, {'who': 'B'});
      await connection.close();
    });

    test('a reply for an unknown id is ignored, not fatal', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      socket.respond(99, {'stray': true});
      final pending = connection.send('A');
      socket.respond(1, {'ok': true});
      expect(await pending, {'ok': true});
      await connection.close();
    });

    test('an error reply fails only its own request', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      final failing = connection.send('A');
      final succeeding = connection.send('B');
      socket.respondWithError(
        -32000,
        'Cannot find node',
        id: 1,
        data: 'nodeId 4',
      );
      socket.respond(2, {'ok': true});

      await expectLater(failing, failsWith(BrowserFailure.protocolError));
      expect(await succeeding, {'ok': true});
      await connection.close();
    });

    test('a protocol error message reaches the caller', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      final pending = connection.send('A');
      socket.respondWithError(-32601, 'X was not found', id: 1);
      await expectLater(
        pending,
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('X was not found'),
          ),
        ),
      );
      await connection.close();
    });
  });

  group('events', () {
    test('republishes event frames', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      final seen = <String>[];
      connection.events.listen((event) => seen.add(event.method));
      socket.emitEvent('Page.loadEventFired');
      socket.emitEvent('Runtime.bindingCalled', {'name': 'x'});
      await pumpEventQueue();
      expect(seen, ['Page.loadEventFired', 'Runtime.bindingCalled']);
      await connection.close();
    });

    test('on() filters by method', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      final loads = connection.on('Page.loadEventFired').take(1).toList();
      socket.emitEvent('Page.frameNavigated');
      socket.emitEvent('Page.loadEventFired', {'timestamp': 3});
      expect((await loads).single.params['timestamp'], 3);
      await connection.close();
    });

    test('a garbled frame is reported but does not kill the socket', () async {
      final errors = <CdpProtocolException>[];
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket, onProtocolError: errors.add);
      socket.emit('}{ not json');
      final pending = connection.send('A');
      socket.respond(1, {'ok': true});
      expect(await pending, {'ok': true});
      expect(errors, hasLength(1));
      await connection.close();
    });
  });

  group('the browser going away', () {
    test(
      'fails every in-flight request instead of leaving them hanging',
      () async {
        final socket = FakeCdpSocket();
        final connection = CdpConnection(socket);
        final first = connection.send('A');
        final second = connection.send('B');
        socket.drop();

        await expectLater(first, failsWith(BrowserFailure.disconnected));
        await expectLater(second, failsWith(BrowserFailure.disconnected));
        expect(connection.isClosed, isTrue);
      },
    );

    test(
      'later sends fail immediately rather than waiting for a timeout',
      () async {
        final socket = FakeCdpSocket();
        final connection = CdpConnection(socket);
        socket.drop();
        await pumpEventQueue();
        expect(
          () => connection.send('A'),
          failsWith(BrowserFailure.disconnected),
        );
      },
    );

    test('a write that throws is reported as a disconnect', () async {
      final socket = FakeCdpSocket()..sendError = StateError('socket closed');
      final connection = CdpConnection(socket);
      expect(
        () => connection.send('A'),
        failsWith(BrowserFailure.disconnected),
      );
    });

    test('done reports the failure that ended the connection', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      socket.drop();
      final failure = await connection.done;
      expect(failure?.failure, BrowserFailure.disconnected);
    });

    test('done is null when we closed it ourselves', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      await connection.close();
      expect(await connection.done, isNull);
      expect(socket.closed, isTrue);
    });
  });

  group('timeouts', () {
    test('an unanswered request times out and stops waiting', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(
        socket,
        defaultTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        connection.send('Silent.method'),
        failsWith(BrowserFailure.timeout),
      );
      // A late reply for the abandoned id must not blow up.
      socket.respond(1, {'late': true});
      await pumpEventQueue();
      await connection.close();
    });

    test('the timeout message names the method', () async {
      final socket = FakeCdpSocket();
      final connection = CdpConnection(socket);
      await expectLater(
        connection.send(
          'Page.captureScreenshot',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('Page.captureScreenshot'),
          ),
        ),
      );
      await connection.close();
    });
  });

  test('a responder-driven socket answers commands automatically', () async {
    final socket = FakeCdpSocket(
      responder: (method, params) => {'echo': method},
    );
    final connection = CdpConnection(socket);
    expect(await connection.send('Page.enable'), {'echo': 'Page.enable'});
    await connection.close();
  });
}
