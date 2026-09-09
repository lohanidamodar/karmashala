import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/flutter_apps/application/android_app_discovery.dart';
import 'package:karmashala/src/features/flutter_apps/application/attached_apps.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala/src/features/flutter_apps/data/dtd_pid_files.dart';
import 'package:karmashala/src/features/flutter_apps/data/vm_service_uri_directory.dart';
import 'package:karmashala/src/features/flutter_apps/domain/attached_app.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_app_registry.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import 'fake_vm_service.dart';

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

void main() {
  late Directory outFiles;
  late Directory pidFiles;
  late Map<String, FakeVmService> reachable;
  late FakeCommandRunner runner;
  late FakeProcessHandle logcat;
  late ProviderContainer container;

  final at = DateTime.utc(2026, 9, 9, 12);

  setUp(() {
    outFiles = Directory.systemTemp.createTempSync('karmashala-vmservice');
    pidFiles = Directory.systemTemp.createTempSync('karmashala-dtd');
    reachable = <String, FakeVmService>{};
    logcat = FakeProcessHandle();
    runner = FakeCommandRunner(
      // `adb forward tcp:0 tcp:<port>` prints the port adb picked. Measured on
      // the owner's emulator: 42771 on the device came back as 59152 here.
      responder: (request) => const CommandResult(
        exitCode: 0,
        stdout: '59152\n',
        stderr: '',
      ),
      processFactory: (_) => logcat,
    );
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(at)),
        flutterAppDiscoveryDirectoryProvider.overrideWith(
          (ref) async => VmServiceUriDirectory(outFiles),
        ),
        dtdPidFilesProvider.overrideWithValue(DtdPidFiles(pidFiles.path)),
        vmServiceConnectorProvider.overrideWithValue((uri) async {
          final fake = reachable[uri.toString()];
          if (fake == null) throw const _Refused();
          return fake.client;
        }),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    for (final directory in [outFiles, pidFiles]) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  AttachedApps apps() => container.read(attachedAppsProvider.notifier);
  FlutterAppRegistry registry() => container.read(attachedAppsProvider);

  AndroidAppDiscovery discovery() => AndroidAppDiscovery(
    adb: AdbService(runner: runner, sdk: _sdk()),
    apps: apps(),
  );

  test('the log line becomes an attached app, through one adb forward', () async {
    reachable['ws://127.0.0.1:59152/nQyjZWDSaNM=/ws'] = FakeVmService();
    final found = discovery();
    await found.watch(const ['emulator-5554']);

    logcat.emitStdout(kCapturedLine);
    await pumpEventQueue();

    expect(found.forwardsMade, 1);
    final row = registry().apps.single;
    expect(row.reachability, AppReachability.attached);
    expect(row.discovery, AppDiscovery.deviceLog);
    expect(row.sourcePath, 'emulator-5554');
    expect(row.observedAt, at);
    found.dispose();
  });

  test('the same announcement twice is one app and one forward', () async {
    reachable['ws://127.0.0.1:59152/nQyjZWDSaNM=/ws'] = FakeVmService();
    final found = discovery();
    await found.watch(const ['emulator-5554']);

    logcat.emitStdout(kCapturedLine);
    await pumpEventQueue();
    logcat.emitStdout(kCapturedLine);
    logcat.emitStdout(kCapturedLine);
    await pumpEventQueue();

    expect(found.forwardsMade, 1);
    expect(registry().apps, hasLength(1));
    found.dispose();
  });

  test('an ordinary log line costs no forward at all', () async {
    final found = discovery();
    await found.watch(const ['emulator-5554']);

    logcat.emitStdout('09-09 14:01:30 4419 4471 I flutter : hello from the app');
    logcat.emitStdout('--------- beginning of main');
    await pumpEventQueue();

    expect(found.forwardsMade, 0);
    expect(registry().apps, isEmpty);
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
    final found = AndroidAppDiscovery(adb: null, apps: apps());
    await found.watch(const ['emulator-5554']);

    expect(found.watching, isEmpty);
    expect(found.forwardsMade, 0);
    found.dispose();
  });
}

class _Refused implements Exception {
  const _Refused();
}
