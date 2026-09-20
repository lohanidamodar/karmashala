import 'dart:async';
import 'dart:io';

import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

/// The real socket's connect path: what happens to a handshake that finishes
/// after the caller has already given up on it.
void main() {
  test(
    'a socket that opens after the timeout is closed, not orphaned',
    () async {
      final serverClosed = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        // Slower than the client's patience, faster than the test's.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen(
          (_) {},
          onDone: () {
            if (!serverClosed.isCompleted) serverClosed.complete();
          },
          onError: (Object _) {},
        );
      });

      await expectLater(
        WebSocketCdpSocket.connect(
          'ws://127.0.0.1:${server.port}/devtools/page/A',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.failure,
            'failure',
            BrowserFailure.timeout,
          ),
        ),
      );

      // `.timeout()` cancels nothing: the handshake still completes, and the
      // late socket used to hold the page as "being debugged" for good.
      await expectLater(
        serverClosed.future.timeout(const Duration(seconds: 5)),
        completes,
      );
    },
  );
}
