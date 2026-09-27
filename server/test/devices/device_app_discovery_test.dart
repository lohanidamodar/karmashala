import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_host/src/devices/device_app_discovery.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// The line captured from a real emulator on 2026-09-09, device port and all.
const String kCapturedLine =
    '09-09 14:01:30.298  4419  4478 I flutter : The Dart VM service is '
    'listening on http://127.0.0.1:42771/nQyjZWDSaNM=/';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'localPosix', path: '/sdk'),
  adb: EnvironmentPath(
    environmentId: 'localPosix',
    path: '/sdk/platform-tools/adb',
  ),
);

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  void advance(Duration by) => now = now.add(by);
  @override
  DateTime nowUtc() => now.toUtc();
}

/// A phone on the server's machine announcing a Flutter app (slice 4a): read
/// from its log, forwarded by the server's own adb and offered to the
/// attached-apps registry — while the apps are being looked at, and only then.
void main() {
  late FakeCommandRunner runner;
  late FakeProcessHandle logcat;
  late List<(Uri, String)> offered;
  late List<String> attached;
  late _Clock clock;

  setUp(() {
    logcat = FakeProcessHandle();
    offered = [];
    attached = ['emulator-5554'];
    clock = _Clock(DateTime.utc(2026, 9, 27, 12));
    runner = FakeCommandRunner(
      environmentId: 'localPosix',
      responder: (request) {
        if (request.arguments.contains('devices')) {
          return CommandResult(
            exitCode: 0,
            stdout:
                'List of devices attached\n'
                '${[for (final s in attached) '$s  device product:sdk model:Pixel transport_id:7'].join('\n')}\n',
            stderr: '',
          );
        }
        // `adb forward tcp:0 tcp:<port>` prints the port adb picked.
        return const CommandResult(exitCode: 0, stdout: '59152\n', stderr: '');
      },
      processFactory: (_) => logcat,
    );
  });

  AdbService adb() => AdbService(runner: runner, sdk: _sdk());

  DeviceAppDiscovery discovery({bool sdk = true}) => DeviceAppDiscovery(
    adb: () async => sdk ? adb() : null,
    offer: ({required hostUri, required serial}) async =>
        offered.add((hostUri, serial)),
    lookingFor: const Duration(minutes: 10),
    rescanEvery: const Duration(hours: 1),
    clock: clock,
  );

  test(
    'looking reads each ready device and forwards its announcement once',
    () async {
      final found = discovery();
      addTearDown(found.close);
      await found.looked();
      expect(found.watching, ['emulator-5554']);

      logcat.emitStdout(kCapturedLine);
      await pumpEventQueue();

      expect(found.forwardsMade, 1);
      final (uri, serial) = offered.single;
      expect(uri.port, 59152);
      expect(uri.path, contains('nQyjZWDSaNM='));
      expect(serial, 'emulator-5554');
    },
  );

  test('the same announcement twice is one offer and one forward', () async {
    final found = discovery();
    addTearDown(found.close);
    await found.looked();

    logcat.emitStdout(kCapturedLine);
    await pumpEventQueue();
    logcat.emitStdout(kCapturedLine);
    logcat.emitStdout(kCapturedLine);
    await pumpEventQueue();

    expect(found.forwardsMade, 1);
    expect(offered, hasLength(1));
  });

  test('an ordinary log line costs no forward at all', () async {
    final found = discovery();
    addTearDown(found.close);
    await found.looked();

    logcat.emitStdout(
      '09-09 14:01:30 4419 4471 I flutter : hello from the app',
    );
    logcat.emitStdout('--------- beginning of main');
    await pumpEventQueue();

    expect(found.forwardsMade, 0);
    expect(offered, isEmpty);
  });

  test('the log is read at adb, filtered to the tags that carry it', () async {
    final found = discovery();
    addTearDown(found.close);
    await found.looked();

    final started = runner.startRequests.single;
    expect(started.arguments, containsAllInOrder(['-s', 'flutter', 'DartVM']));
    expect(started.arguments, contains('logcat'));
    expect(started.arguments, isNot(contains('-d')));
  });

  test('a replayed ring buffer cannot cost unbounded forwards', () async {
    final found = discovery();
    addTearDown(found.close);
    await found.looked();

    for (var port = 1; port <= kMaxDeviceAnnouncements + 5; port++) {
      logcat.emitStdout(
        'I flutter : The Dart VM service is listening on '
        'http://127.0.0.1:$port/tok$port=/',
      );
      await pumpEventQueue();
    }

    expect(found.forwardsMade, kMaxDeviceAnnouncements);
  });

  test('nothing is read until somebody looks', () async {
    final found = discovery();
    addTearDown(found.close);
    await pumpEventQueue();
    expect(found.active, isFalse);
    expect(runner.startRequests, isEmpty);
  });

  test('once nobody has looked for a while, every reader stops', () async {
    final found = DeviceAppDiscovery(
      adb: () async => adb(),
      offer: ({required hostUri, required serial}) async {},
      lookingFor: const Duration(minutes: 10),
      rescanEvery: const Duration(milliseconds: 5),
      clock: clock,
    );
    addTearDown(found.close);
    await found.looked();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(found.active, isTrue, reason: 'still inside the lease');
    expect(logcat.killed, isFalse);

    clock.advance(const Duration(minutes: 10));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(found.active, isFalse);
    expect(logcat.killed, isTrue);
    expect(found.watching, isEmpty);
  });

  test('a device that went away is no longer read', () async {
    final found = discovery();
    addTearDown(found.close);
    await found.looked();
    attached = [];
    await found.looked();

    expect(logcat.killed, isTrue);
    expect(found.watching, isEmpty);
  });

  test('closing stops every reader', () async {
    final found = discovery();
    await found.looked();
    expect(found.watching, ['emulator-5554']);

    found.close();

    expect(logcat.killed, isTrue);
    expect(found.watching, isEmpty);
    expect(found.active, isFalse);
  });

  test('no Android SDK is not a crash, it is no devices', () async {
    final found = discovery(sdk: false);
    addTearDown(found.close);
    await found.looked();

    expect(found.watching, isEmpty);
    expect(found.forwardsMade, 0);
  });
}
