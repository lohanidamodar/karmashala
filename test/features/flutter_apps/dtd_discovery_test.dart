import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/flutter_apps/application/attached_apps.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

import '../../support/fakes.dart';
import 'fake_dtd.dart';
import 'fake_vm_service.dart';

void main() {
  late Directory outFiles;
  late Directory pidFiles;
  late Map<String, FakeVmService> reachable;
  late Map<String, FakeDtd> daemons;
  late List<Uri> opened;
  late ProviderContainer container;

  final at = DateTime.utc(2026, 9, 9, 12);

  /// The daemon writes one of these when it starts. Shape verified against the
  /// real file on 2026-09-09.
  void writePidFile(int pid, String wsUri, {String workspaceRoot = r'C:\kw\app'}) =>
      File('${pidFiles.path}${Platform.pathSeparator}$pid').writeAsStringSync(
        '{"wsUri":"$wsUri","epoch":1788941794103,"pid":$pid,'
        '"workspaceRoot":"${workspaceRoot.replaceAll(r'\', r'\\')}"}',
      );

  FakeDtd serveDaemon(String wsUri, {List<Map<String, Object?>> apps = const []}) {
    final daemon = FakeDtd(apps: apps);
    daemons[wsUri] = daemon;
    return daemon;
  }

  FakeVmService serveApp(String wsUri) {
    final fake = FakeVmService();
    reachable[wsUri] = fake;
    return fake;
  }

  setUp(() {
    outFiles = Directory.systemTemp.createTempSync('karmashala-vmservice');
    pidFiles = Directory.systemTemp.createTempSync('karmashala-dtd');
    reachable = <String, FakeVmService>{};
    daemons = <String, FakeDtd>{};
    opened = <Uri>[];
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(at)),
        flutterAppDiscoveryDirectoryProvider.overrideWith(
          (ref) async => VmServiceUriDirectory(outFiles),
        ),
        dtdPidFilesProvider.overrideWithValue(DtdPidFiles(pidFiles.path)),
        dtdChannelOpenerProvider.overrideWithValue((Uri uri) async {
          opened.add(uri);
          final daemon = daemons[uri.toString()];
          if (daemon == null) throw const SocketException('refused');
          return daemon;
        }),
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

  test('a flutter run started in somebody else terminal is attached', () async {
    const daemon = 'ws://127.0.0.1:54382/xkQinOxHDeY=';
    const app = 'ws://127.0.0.1:54385/Rzp5Wq0-P2o=/ws';
    writePidFile(36984, daemon, workspaceRoot: r'C:\kw\vmprobe');
    serveDaemon(
      daemon,
      apps: [
        {'uri': app, 'name': 'Kind: Flutter - Device: sdk gphone64 - Package: vmprobe'},
      ],
    );
    serveApp(app);

    await apps().look();

    final row = registry().apps.single;
    expect(row.reachability, AppReachability.attached);
    expect(row.discovery, AppDiscovery.toolingDaemon);
    expect(row.label, contains('Package: vmprobe'));
    // The project the daemon was started in, so two runs are told apart.
    expect(row.sourcePath, r'C:\kw\vmprobe');
    expect(row.observedAt, at);
  });

  test('nothing is asked of the user: no out-file, no pasted address', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    const app = 'ws://127.0.0.1:2/a=/ws';
    writePidFile(11, daemon);
    serveDaemon(daemon, apps: [
      {'uri': app},
    ]);
    serveApp(app);

    await apps().look();

    expect(outFiles.listSync(), isEmpty);
    expect(registry().attached, hasLength(1));
    // The label falls back to the project directory, never to a bare id.
    expect(registry().apps.single.label, 'app');
  });

  test('an app that registers later arrives as an event, not a poll', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    const app = 'ws://127.0.0.1:2/late=/ws';
    writePidFile(11, daemon);
    final fake = serveDaemon(daemon);
    serveApp(app);

    await apps().look();
    expect(registry().apps, isEmpty);

    fake.announce(app, name: 'Kind: Flutter - Package: later');
    await pumpEventQueue();

    expect(registry().attached, hasLength(1));
    expect(registry().apps.single.label, 'Kind: Flutter - Package: later');
  });

  test('offers one app once, however often it is named', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    const app = 'ws://127.0.0.1:2/a=/ws';
    writePidFile(11, daemon);
    final fake = serveDaemon(daemon, apps: [
      {'uri': app},
    ]);
    serveApp(app);

    await apps().look();
    fake.announce(app);
    await pumpEventQueue();
    await apps().look();

    expect(registry().apps, hasLength(1));
    // One handshake per app. A second connection would cost the app one for
    // nothing and give this row a second console.
    expect(reachable[app]!.methods.where((m) => m == 'getVM'), hasLength(1));
  });

  test('one daemon is opened once, not once per look', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    writePidFile(11, daemon);
    serveDaemon(daemon);

    await apps().look();
    await apps().look();
    await apps().look();

    expect(opened, hasLength(1));
  });

  test('a daemon whose pid file outlived it is dropped, not reported', () async {
    writePidFile(11, 'ws://127.0.0.1:9/dead=');

    await apps().look();

    expect(registry().discoveryFailure, isNull);
    expect(registry().apps, isEmpty);
    expect(describeRegistry(registry()), 'No Flutter app is running that we can see.');
  });

  test('a row whose daemon stopped naming it is dropped', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    const app = 'ws://127.0.0.1:2/a=/ws';
    writePidFile(11, daemon);
    serveDaemon(daemon, apps: [
      {'uri': app},
    ]);
    // Nothing answers on the app, so the row is a candidate that stays only as
    // long as the daemon names it.
    await apps().look();
    expect(registry().apps, hasLength(1));

    daemons.remove(daemon);
    File('${pidFiles.path}${Platform.pathSeparator}11').deleteSync();
    await apps().look();

    expect(registry().apps, isEmpty);
  });

  test('closing the registry closes the daemon connections', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    writePidFile(11, daemon);
    final fake = serveDaemon(daemon);
    await apps().look();
    expect(fake.closed, isFalse);

    container.dispose();
    await pumpEventQueue();

    expect(fake.closed, isTrue);
  });
}

class _Refused implements Exception {
  const _Refused();
}
