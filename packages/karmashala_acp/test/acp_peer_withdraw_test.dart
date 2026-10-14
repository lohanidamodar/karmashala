import 'dart:async';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:test/test.dart';

/// A request its sender withdraws: the other side is told with
/// `$/cancel_request`, sees it cancelled, and its -32800 ends the call.
void main() {
  test(
    'a withdrawn call is cancelled on the other side and ends -32800',
    () async {
      final aToB = StreamController<List<int>>();
      final bToA = StreamController<List<int>>();
      final a = AcpPeer(bToA.stream, aToB.sink);
      final b = AcpPeer(aToB.stream, bToA.sink);
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      final received = Completer<AcpIncomingRequest>();
      b.requests.listen(received.complete);

      final withdrawn = Completer<void>();
      final call = a.call('session/request_permission', {
        'sessionId': 's',
      }, withdrawn: withdrawn.future);
      final request = await received.future;
      expect(request.isCancelled, isFalse);

      withdrawn.complete();
      await expectLater(
        call,
        throwsA(
          isA<AcpRpcError>().having(
            (e) => e.code,
            'code',
            JsonRpcErrorCodes.requestCancelled,
          ),
        ),
      );
      expect(request.isCancelled, isTrue);
    },
  );

  test('a call answered before it is withdrawn says nothing more', () async {
    final aToB = StreamController<List<int>>();
    final bToA = StreamController<List<int>>();
    final a = AcpPeer(bToA.stream, aToB.sink);
    final b = AcpPeer(aToB.stream, bToA.sink);
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    final notifications = <AcpNotification>[];
    b.notifications.listen(notifications.add);
    b.requests.listen((request) => request.respond({'ok': true}));

    final withdrawn = Completer<void>();
    expect(await a.call('x', const {}, withdrawn: withdrawn.future), {
      'ok': true,
    });
    withdrawn.complete();
    await Future<void>.delayed(Duration.zero);
    expect(notifications, isEmpty);
  });
}
