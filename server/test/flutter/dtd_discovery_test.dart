import 'dart:io';

import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_host/src/flutter/attached_apps.dart';
import 'package:test/test.dart';

import 'fake_dtd.dart';
import 'fake_vm_service.dart';

void main() {
  late Directory outFiles;
  late Directory pidFiles;
  late Map<String, FakeVmService> reachable;
  late Map<String, FakeDtd> daemons;
  late List<Uri> opened;
  late ServerAttachedApps apps;
  final at = DateTime.utc(2026, 9, 9, 12);

  void writePidFile(
    int pid,
    String wsUri, {
    String workspaceRoot = r'C:\kw\app',
  }) => File('${pidFiles.path}${Platform.pathSeparator}$pid').writeAsStringSync(
    '{"wsUri":"$wsUri","epoch":1788941794103,"pid":$pid,'
    '"workspaceRoot":"${workspaceRoot.replaceAll(r'\', r'\\')}"}',
  );

  FakeDtd serveDaemon(
    String wsUri, {
    List<Map<String, Object?>> apps = const [],
  }) => daemons[wsUri] = FakeDtd(apps: apps);

  FakeVmService serveApp(String wsUri) => reachable[wsUri] = FakeVmService();

  setUp(() {
    outFiles = Directory.systemTemp.createTempSync('karmashala-vmservice');
    pidFiles = Directory.systemTemp.createTempSync('karmashala-dtd');
    reachable = {};
    daemons = {};
    opened = [];
    apps = ServerAttachedApps(
      directory: VmServiceUriDirectory(outFiles),
      dtdPidFiles: DtdPidFiles([pidFiles.path]),
      openDtd: (uri) async {
        opened.add(uri);
        final daemon = daemons[uri.toString()];
        if (daemon == null) throw const SocketException('refused');
        return daemon;
      },
      connect: (uri) async {
        final fake = reachable[uri.toString()];
        if (fake == null) throw const SocketException('refused');
        return fake.client;
      },
      clock: () => at,
    );
  });

  tearDown(() async {
    await apps.close();
    for (final directory in [outFiles, pidFiles]) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  FlutterAppRegistry registry() => apps.registry;

  test('a flutter run in somebody else\'s terminal is attached', () async {
    const daemon = 'ws://127.0.0.1:54382/xkQinOxHDeY=';
    const app = 'ws://127.0.0.1:54385/Rzp5Wq0-P2o=/ws';
    writePidFile(36984, daemon, workspaceRoot: r'C:\kw\vmprobe');
    serveDaemon(
      daemon,
      apps: [
        {
          'uri': app,
          'name': 'Kind: Flutter - Device: sdk gphone64 - Package: vmprobe',
        },
      ],
    );
    serveApp(app);
    await apps.look();
    final row = registry().apps.single;
    expect(row.reachability, AppReachability.attached);
    expect(row.discovery, AppDiscovery.toolingDaemon);
    expect(row.label, contains('Package: vmprobe'));
    expect(row.sourcePath, r'C:\kw\vmprobe');
    expect(row.observedAt, at);
  });

  test('the first daemon ever arrives without another look', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    const app = 'ws://127.0.0.1:2/first=/ws';
    pidFiles.deleteSync(recursive: true);
    serveDaemon(
      daemon,
      apps: [
        {'uri': app},
      ],
    );
    serveApp(app);
    await apps.look();
    expect(registry().apps, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    pidFiles.createSync();
    writePidFile(11, daemon);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (registry().attached.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(registry().attached, hasLength(1));
  });

  test('an app that registers later arrives as an event', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    const app = 'ws://127.0.0.1:2/late=/ws';
    writePidFile(11, daemon);
    final fake = serveDaemon(daemon);
    serveApp(app);
    await apps.look();
    expect(registry().apps, isEmpty);
    fake.announce(app, name: 'Kind: Flutter - Package: later');
    await pumpEventQueue();
    expect(registry().attached, hasLength(1));
  });

  test('offers one app once, however often it is named', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    const app = 'ws://127.0.0.1:2/a=/ws';
    writePidFile(11, daemon);
    final fake = serveDaemon(
      daemon,
      apps: [
        {'uri': app},
      ],
    );
    serveApp(app);
    await apps.look();
    fake.announce(app);
    await pumpEventQueue();
    await apps.look();
    expect(registry().apps, hasLength(1));
    expect(reachable[app]!.methods.where((m) => m == 'getVM'), hasLength(1));
  });

  test('one daemon is opened once, not once per look', () async {
    writePidFile(11, 'ws://127.0.0.1:1/d=');
    serveDaemon('ws://127.0.0.1:1/d=');
    await apps.look();
    await apps.look();
    expect(opened, hasLength(1));
  });

  test(
    'a daemon whose pid file outlived it is dropped, not reported',
    () async {
      writePidFile(11, 'ws://127.0.0.1:9/dead=');
      await apps.look();
      expect(registry().discoveryFailure, isNull);
      expect(registry().apps, isEmpty);
    },
  );

  test('a row whose daemon stopped naming it is dropped', () async {
    const daemon = 'ws://127.0.0.1:1/d=';
    writePidFile(11, daemon);
    serveDaemon(
      daemon,
      apps: [
        {'uri': 'ws://127.0.0.1:2/a=/ws'},
      ],
    );
    await apps.look();
    expect(registry().apps, hasLength(1));
    daemons.remove(daemon);
    File('${pidFiles.path}${Platform.pathSeparator}11').deleteSync();
    await apps.look();
    expect(registry().apps, isEmpty);
  });

  test('closing lets go of the daemon connections', () async {
    writePidFile(11, 'ws://127.0.0.1:1/d=');
    final fake = serveDaemon('ws://127.0.0.1:1/d=');
    await apps.look();
    expect(fake.closed, isFalse);
    await apps.close();
    expect(fake.closed, isTrue);
  });
}
