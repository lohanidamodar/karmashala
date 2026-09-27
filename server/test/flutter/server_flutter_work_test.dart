import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_host/src/data/data_streams.dart';
import 'package:test/test.dart';

import 'flutter_fixture.dart';

void main() {
  late FlutterFixture fixture;
  const wsUri = 'ws://127.0.0.1:53119/tok=/ws';

  setUp(() => fixture = FlutterFixture());
  tearDown(() => fixture.close());

  test(
    'a client attaches, reloads and detaches through the requests',
    () async {
      final fake = fixture.reachable[wsUri] = FakeVmService();
      final app =
          await fixture.work.handle(
                const FlutterAttach(
                  'http://127.0.0.1:53119/tok=/',
                  deviceSerial: 'emulator-5554',
                ),
              )
              as AttachedApp;
      expect(app.discovery, AppDiscovery.deviceLog);
      fake.emitServiceRegistered('reloadSources', 's1.reloadSources');
      await settle();
      await fixture.work.handle(FlutterReload(app.id));
      expect(fake.methods, contains('s1.reloadSources'));
      await fixture.work.handle(FlutterDetach(app.id));
      final registry =
          await fixture.work.handle(const FlutterApps()) as FlutterAppRegistry;
      expect(registry.byId(app.id)!.isAttached, isFalse);
    },
  );

  test('a failure is refused in the failure\'s own words', () async {
    await expectLater(
      fixture.work.handle(const FlutterAttach('ws://127.0.0.1:9/gone=/ws')),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.failed)
            .having((r) => r.message, 'message', contains('Nothing answered')),
      ),
    );
    await expectLater(
      fixture.work.handle(const FlutterReload('nobody')),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
  });

  test('a pick answers the sentence an agent reads', () async {
    final fake = fixture.reachable[wsUri] = FakeVmService(
      selectedWidget: const {'description': 'Text'},
    );
    final app = await fixture.work.apps.attach(wsUri);
    final pick = fixture.work.handle(FlutterPickWidget(app.id));
    await settle();
    fake.emitNavigate();
    expect(await pick, contains('Widget: Text'));
  });

  test('flutter.sdk reads the environment it names, or refuses', () async {
    final reading =
        await fixture.work.handle(const FlutterSdk('wsl:Ubuntu'))
            as FlutterSdkReading;
    expect(reading.executable, '/home/me/flutter/bin/flutter');
    await expectLater(
      fixture.work.handle(const FlutterSdk('gone')),
      throwsA(isA<DataRefused>()),
    );
  });

  test('a new client is told the runs still going, and the apps once the '
      'server has looked', () async {
    expect(fixture.work.greeting(), isEmpty);
    await fixture.work.loop.pubGet(wslProject);
    await fixture.work.apps.look();
    final greeting = fixture.work.greeting();
    expect(greeting.whereType<FlutterAppsChanged>(), hasLength(1));
    expect(greeting.whereType<HostedRunChanged>().single.run.isLive, isTrue);
  });

  test('a console is followed on a data stream, bounded', () async {
    final fake = fixture.reachable[wsUri] = FakeVmService();
    final app = await fixture.work.apps.attach(wsUri);
    final batches = <DataStreamItems>[];
    final streams = DataStreamSession(
      {kFlutterLogsStream: fixture.work.logs},
      batches.add,
      flushEvery: const Duration(milliseconds: 5),
      capacity: 2,
    );
    streams.open(DataStreamEnvelope.open(7, kFlutterLogsStream, app.id));
    for (final line in ['a', 'b', 'c']) {
      fake.emitStdout('$line\n', at: fixtureNow.add(const Duration(hours: 1)));
    }
    await settle();
    final live = batches.last;
    expect(live.streamId, 7);
    expect(live.dropped, 1);
    expect(live.items.map((i) => (i! as Map)['message']), ['b', 'c']);
    streams.open(DataStreamEnvelope.open(8, kFlutterLogsStream, 'nobody'));
    expect(batches.last.ended, contains('nobody'));
    streams.closeAll();
  });
}
