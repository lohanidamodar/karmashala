import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/server/remote_server_access.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_remote/client.dart';

/// Counts every read: each dial starts by loading the pairing, so a read is
/// a dial begun.
class _CountingStore extends InMemoryCompanionStore {
  var reads = 0;

  @override
  Future<String?> read(String key) {
    reads++;
    return super.read(key);
  }
}

/// **No dial in the background** (round 116): a link that ended in the
/// grace was redialled at once, before the hang-up, and every redial after
/// it woke the phone. From [RemoteServerAccess.rest] until
/// [RemoteServerAccess.wake], a dial waits.
void main() {
  late _CountingStore store;
  late RemoteServerAccess access;

  RemoteServerAccess build() => RemoteServerAccess(
    hostId: 'host-1',
    hostName: 'box',
    store: store,
    dialer: DesktopServerDialer(store: store),
  );

  setUp(() => store = _CountingStore());

  testWidgets('in front, a dial goes through at once', (tester) async {
    access = build();
    Object? outcome;
    unawaited(
      access.exec('host').then((_) {}, onError: (Object e) => outcome = e),
    );
    await tester.pump();
    expect(store.reads, greaterThan(0));
    expect(outcome, isA<HostLinkException>());
    await access.close();
  });

  testWidgets('backgrounded, no dial starts — in the grace or after it — '
      'until the app is back', (tester) async {
    access = build();
    await tester.pump();
    access.rest();
    final before = store.reads;
    Object? outcome;
    unawaited(
      access.exec('host').then((_) {}, onError: (Object e) => outcome = e),
    );

    // Inside the grace: the link that ended is not redialled.
    await tester.pump(const Duration(seconds: 30));
    expect(store.reads, before);
    expect(outcome, isNull);

    // Long past it: still nothing, however many redials are queued.
    unawaited(access.exec('host').then((_) {}, onError: (_) {}));
    await tester.pump(kBackgroundLinkGrace * 10);
    expect(store.reads, before);
    expect(outcome, isNull);

    access.wake();
    await tester.pump();
    expect(store.reads, greaterThan(before));
    expect(outcome, isA<HostLinkException>());
    await access.close();
  });

  testWidgets('a close while backgrounded lets a waiting dial end', (
    tester,
  ) async {
    access = build();
    access.rest();
    Object? outcome;
    unawaited(
      access.exec('host').then((_) {}, onError: (Object e) => outcome = e),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(outcome, isNull);
    await access.close();
    await tester.pump();
    expect(outcome, isA<HostLinkException>());
  });
}
