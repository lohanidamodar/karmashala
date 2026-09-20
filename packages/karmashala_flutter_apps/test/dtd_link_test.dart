import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:test/test.dart';

import 'fake_dtd.dart';

void main() {
  Future<DtdLink> openOver(FakeDtd daemon) =>
      DtdLink.open(Uri.parse('ws://127.0.0.1:1/x'), open: (_) async => daemon);

  test('the app stream is subscribed before anything is asked', () async {
    final daemon = FakeDtd();
    final link = await openOver(daemon);
    expect(daemon.calls, ['streamListen']);
    await link.dispose();
  });

  test('the apps the daemon already knows come back', () async {
    final daemon = FakeDtd(
      apps: [
        {'uri': 'http://127.0.0.1:8181/tok=/', 'name': 'an_app'},
      ],
    );
    final link = await openOver(daemon);
    final apps = await link.apps();
    expect(apps.single.name, 'an_app');
    expect(apps.single.uri.scheme, 'ws');
    await link.dispose();
  });

  test('an app that registers later arrives as an event, not a poll', () async {
    final daemon = FakeDtd();
    final link = await openOver(daemon);
    final seen = link.registered.first;
    daemon.announce('http://127.0.0.1:8182/tok=/', name: 'later');
    expect((await seen).name, 'later');
    await link.dispose();
  });

  test(
    'a daemon that closed the connection is unavailable, not a hang',
    () async {
      final daemon = FakeDtd();
      final link = await openOver(daemon);
      await daemon.close();
      await expectLater(link.apps(), throwsA(isA<DtdUnavailable>()));
      await link.dispose();
    },
  );

  test('dispose closes the channel', () async {
    final daemon = FakeDtd();
    final link = await openOver(daemon);
    await link.dispose();
    expect(daemon.closed, isTrue);
  });
}
