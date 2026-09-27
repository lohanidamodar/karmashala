import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/application/android_app_discovery.dart';
import 'package:karmashala_devices/devices.dart';

import '../../support/fake_command_runner.dart';

/// The line captured from a real emulator on 2026-09-09, device port and all.
const String kCapturedLine =
    '09-09 14:01:30.298  4419  4478 I flutter : The Dart VM service is '
    'listening on http://127.0.0.1:42771/nQyjZWDSaNM=/';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

/// A phone's announcement, forwarded here and handed to the server, which
/// attaches (slice 3d): the devices are this app's, the attaching the
/// server's.
void main() {
  late FakeCommandRunner runner;
  late FakeProcessHandle logcat;
  late List<(Uri, String)> offered;

  setUp(() {
    logcat = FakeProcessHandle();
    offered = [];
    runner = FakeCommandRunner(
      // `adb forward tcp:0 tcp:<port>` prints the port adb picked. Measured on
      // the owner's emulator: 42771 on the device came back as 59152 here.
      responder: (request) =>
          const CommandResult(exitCode: 0, stdout: '59152\n', stderr: ''),
      processFactory: (_) => logcat,
    );
  });

  AndroidAppDiscovery discovery({bool adb = true}) => AndroidAppDiscovery(
    adb: adb ? AdbService(runner: runner, sdk: _sdk()) : null,
    offer: ({required hostUri, required serial}) async =>
        offered.add((hostUri, serial)),
  );

  test(
    'the log line is handed to the server, through one adb forward',
    () async {
      final found = discovery();
      await found.watch(const ['emulator-5554']);

      logcat.emitStdout(kCapturedLine);
      await pumpEventQueue();

      expect(found.forwardsMade, 1);
      final (uri, serial) = offered.single;
      expect(uri.port, 59152);
      expect(uri.path, contains('nQyjZWDSaNM='));
      expect(serial, 'emulator-5554');
      found.dispose();
    },
  );

  test('the same announcement twice is one offer and one forward', () async {
    final found = discovery();
    await found.watch(const ['emulator-5554']);

    logcat.emitStdout(kCapturedLine);
    await pumpEventQueue();
    logcat.emitStdout(kCapturedLine);
    logcat.emitStdout(kCapturedLine);
    await pumpEventQueue();

    expect(found.forwardsMade, 1);
    expect(offered, hasLength(1));
    found.dispose();
  });

  test('an ordinary log line costs no forward at all', () async {
    final found = discovery();
    await found.watch(const ['emulator-5554']);

    logcat.emitStdout(
      '09-09 14:01:30 4419 4471 I flutter : hello from the app',
    );
    logcat.emitStdout('--------- beginning of main');
    await pumpEventQueue();

    expect(found.forwardsMade, 0);
    expect(offered, isEmpty);
    found.dispose();
  });

  test('the log is read at adb, filtered to the tags that carry it', () async {
    final found = discovery();
    await found.watch(const ['emulator-5554']);

    final started = runner.startRequests.single;
    expect(started.arguments, containsAllInOrder(['-s', 'flutter', 'DartVM']));
    expect(started.arguments, contains('logcat'));
    // Never `-d`: a snapshot would have to be asked for again, which is a poll.
    expect(started.arguments, isNot(contains('-d')));
    found.dispose();
  });

  test('a replayed ring buffer cannot cost unbounded forwards', () async {
    final found = discovery();
    await found.watch(const ['emulator-5554']);

    for (var port = 1; port <= kMaxDeviceAnnouncements + 5; port++) {
      logcat.emitStdout(
        'I flutter : The Dart VM service is listening on '
        'http://127.0.0.1:$port/tok$port=/',
      );
      await pumpEventQueue();
    }

    expect(found.forwardsMade, kMaxDeviceAnnouncements);
    found.dispose();
  });

  test('a closed pane subscribes to nothing', () async {
    final found = discovery();
    await found.watch(const ['emulator-5554']);
    expect(found.watching, ['emulator-5554']);
    expect(logcat.killed, isFalse);

    found.dispose();

    expect(logcat.killed, isTrue);
    expect(found.watching, isEmpty);
  });

  test('a device that went away is no longer read', () async {
    final found = discovery();
    await found.watch(const ['emulator-5554']);
    await found.watch(const <String>[]);

    expect(logcat.killed, isTrue);
    expect(found.watching, isEmpty);
    found.dispose();
  });

  test('no Android SDK is not a crash, it is no devices', () async {
    final found = discovery(adb: false);
    await found.watch(const ['emulator-5554']);

    expect(found.watching, isEmpty);
    expect(found.forwardsMade, 0);
    found.dispose();
  });
}
