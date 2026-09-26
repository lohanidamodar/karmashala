/// `serve --standalone` in this process, on temp directories: its own store
/// (created, or the app's, or refused when newer), its own config, pairing,
/// devices and revoke from the CLI, and the agent CLIs it records.
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/process.dart' show EnvironmentKind;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart' show HostLifecycleWatch;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'server_test_support.dart';

void main() {
  late Directory root;
  late String dataDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('kh-standalone');
    dataDir = p.join(root.path, 'data');
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<String> standalone([List<String> more = const []]) => [
    '--standalone',
    '--data-dir=$dataDir',
    '--companion-port=0',
    '--mcp-port=0',
    ...more,
  ];

  int userVersion(String dir) {
    final db = AppDatabase.open(Directory(dir));
    try {
      return db.query('PRAGMA user_version;').single['user_version']! as int;
    } finally {
      db.close();
    }
  }

  group('its own store', () {
    test('a fresh data directory gets a store at the schema this build '
        'carries, owner-only', () async {
      final server = await InProcessServer.start(root, standalone());
      addTearDown(server.stop);
      expect(
        server.out.text.toString(),
        contains('standalone server "${Platform.localHostname}", data in '),
      );
      expect(await server.stop(), 0, reason: '${server.err.text}');

      final store = File(p.join(dataDir, kStoreFileName));
      expect(store.existsSync(), isTrue);
      final expected = AppDatabase.memory();
      addTearDown(expected.close);
      expect(userVersion(dataDir), expected.schemaVersion);
      expect(Directory(dataDir).statSync().mode & 0x1ff, 0x1c0);
    });

    test('a data directory the app already migrated is opened as it is — '
        'its rows kept, nothing re-run', () async {
      Directory(dataDir).createSync(recursive: true);
      final app = AppDatabase.open(Directory(dataDir));
      app.writeMetadata('written.by', 'the app');
      final version = app.schemaVersion;
      app.close();

      final server = await InProcessServer.start(root, standalone());
      expect(await server.stop(), 0, reason: '${server.err.text}');

      expect(userVersion(dataDir), version);
      final db = AppDatabase.open(Directory(dataDir));
      addTearDown(db.close);
      expect(db.readMetadata('written.by'), 'the app');
    });

    test(
      'a store a newer build migrated is refused, and nothing serves',
      () async {
        Directory(dataDir).createSync(recursive: true);
        final newer = AppDatabase.open(Directory(dataDir));
        newer.execute('PRAGMA user_version = ${newer.schemaVersion + 1};');
        newer.close();

        final out = CapturingSink();
        final err = CapturingSink();
        final code = await runServe(
          standalone(),
          out: out,
          err: err,
          paths: HostPaths(Directory(p.join(root.path, 'host'))),
          agentsFor: noAgents,
        );
        expect(code, 7);
        expect(err.text.toString(), contains('a newer Karmashala migrated it'));
        expect(out.text.toString(), isNot(contains('serving on')));
      },
    );

    test('a host the app starts keeps running without the store it cannot '
        'open', () async {
      Directory(dataDir).createSync(recursive: true);
      final newer = AppDatabase.open(Directory(dataDir));
      newer.execute('PRAGMA user_version = ${newer.schemaVersion + 1};');
      newer.close();
      final server = await InProcessServer.start(root, [
        '--data-dir=$dataDir',
        '--companion-port=0',
        '--mcp-port=0',
      ]);
      expect(server.out.text.toString(), contains('no store'));
      expect(await server.stop(), 0);
    });
  });

  group('its own session records', () {
    const request = PtySpawnRequest(argv: ['/bin/sh'], columns: 80, rows: 24);

    test('another host\'s records in the user\'s runtime dir are not '
        'restored, and are left as they were', () async {
      final hostDir = Directory(p.join(root.path, 'host'));
      final sessions = Directory(HostPaths(hostDir).sessionsDirectory);
      final appHome = Directory(p.join(root.path, 'app-data'))..createSync();
      final theirs = SessionStore(sessions, owner: storeOwnerOf(appHome.path))
        ..ensureDirectory();
      for (var i = 0; i < 3; i++) {
        theirs.open('app-$i', request, DateTime.utc(2026, 9, 26))
          ..ended(SessionExited(0, DateTime.utc(2026, 9, 26, 1)))
          ..close();
      }

      final server = await InProcessServer.start(root, standalone());
      addTearDown(server.stop);
      expect(
        server.out.text.toString(),
        contains('restored 0 session(s) from ${sessions.path}'),
      );
      expect(await server.stop(), 0, reason: '${server.err.text}');
      expect(
        SessionStore(
          sessions,
          owner: storeOwnerOf(appHome.path),
        ).restore().map((s) => s.id).toSet(),
        {'app-0', 'app-1', 'app-2'},
      );
    });

    test('a second server as the same user is refused, naming the data '
        'directory of the one that holds the socket', () async {
      final first = await InProcessServer.start(root, standalone());
      addTearDown(first.stop);
      // A process of its own: the lock is a POSIX record lock, which never
      // conflicts with its own process.
      final second = await Process.run(
        Platform.resolvedExecutable,
        [
          'bin/karmashala_host.dart',
          'serve',
          '--standalone',
          '--data-dir=${p.join(root.path, 'other-data')}',
          '--companion-port=0',
          '--mcp-port=0',
        ],
        environment: {
          'HOME': p.join(root.path, 'home'),
          kHostDirectoryEnvironmentVariable: first.paths.directory.path,
        },
      ).timeout(const Duration(minutes: 2));
      expect(second.exitCode, 3, reason: '${second.stdout}${second.stderr}');
      expect('${second.stderr}', contains('data in $dataDir'));
      expect('${second.stderr}', contains('pid $pid'));
      expect(await first.stop(), 0, reason: '${first.err.text}');
      expect(
        File(first.paths.holderDataDirectoryPath).existsSync(),
        isFalse,
        reason: 'a server that stopped holds nothing to name',
      );
    });
  });

  group('its own config', () {
    test('server.json is served by, and a flag overrides it', () async {
      await const ServerConfig(
        name: 'from-file',
        companionPort: 1,
        bind: '127.0.0.1',
      ).write(dataDir);
      final server = await InProcessServer.start(
        root,
        standalone(['--name=from-flag']),
      );
      addTearDown(server.stop);
      final said = server.out.text.toString();
      expect(said, contains('standalone server "from-flag"'));
      // `--companion-port=0` beat the file's 1.
      expect(server.companionPort, isNot(1));
      expect(said, contains('(bound to 127.0.0.1)'));
    });

    test('a config that cannot be served by is refused before anything '
        'binds', () async {
      Directory(dataDir).createSync(recursive: true);
      File(
        p.join(dataDir, kServerConfigFileName),
      ).writeAsStringSync('{"companion": {"bind": "everywhere"}}');
      final hostDir = Directory(p.join(root.path, 'host'));
      final err = CapturingSink();
      final code = await runServe(
        standalone(),
        out: CapturingSink(),
        err: err,
        paths: HostPaths(hostDir),
        agentsFor: noAgents,
      );
      expect(code, 2);
      expect(err.text.toString(), contains('not an IP address'));
      expect(hostDir.existsSync(), isFalse);
    });

    test('the companion comes up from the file with no app, and an app '
        'that connects is the authority only while connected', () async {
      final relay = Uri.parse('wss://relay.example.com');
      await ServerConfig(
        relay: relay,
        relayToken: 'a' * 32,
        beacon: false,
      ).write(dataDir);
      final database = <AppDatabase>[];
      final server = await InProcessServer.start(
        root,
        standalone(),
        agentsFor: (db) {
          database.add(db);
          return noAgents(db);
        },
      );
      addTearDown(server.stop);

      final client = (await HostClient.connect(server.paths.socketPath))!;
      addTearDown(client.close);
      Future<String?> servedRelay() async {
        final info = await client.call(ServerMethod.serverInfo);
        return (info['companion']! as Map)['relay'] as String?;
      }

      // The token is spelled into the path and never said back.
      expect(await servedRelay(), 'wss://relay.example.com/k/…');

      final app = (await HostLifecycleWatch.connect(server.paths.socketPath))!;
      app.configureCompanion({'enabled': true, 'hostedEnabled': false});
      // The config is applied in order with this link's frames; the next
      // answer on another link comes after it.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await servedRelay(), isNull);

      await app.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await servedRelay(), 'wss://relay.example.com/k/…');
    });
  });

  group('pairing from the CLI', () {
    test('pair opens a window, prints a code, a QR and a payload that '
        'decodes, and reports the phone that paired; devices lists it and '
        'revoke revokes it', () async {
      final server = await InProcessServer.start(root, standalone());
      addTearDown(server.stop);
      final port = server.companionPort;

      final out = CapturingSink();
      final err = CapturingSink();
      final pairing = runPair(
        [
          '--capabilities=view_sessions,approve',
          '--name=Test phone',
          '--address=box.example.com',
          '--no-color',
        ],
        out: out,
        err: err,
        paths: server.paths,
      );
      await Future.any([
        out.saw('Waiting for a device to pair'),
        pairing.then((code) => fail('pair exited $code: ${err.text}')),
      ]);
      final printed = out.text.toString();
      final code = RegExp(r'Code:\s+(\S+)').firstMatch(printed)!.group(1)!;
      expect(PairingCode.tryDecode(code), isNotNull);
      expect(printed, contains('Route:    direct'));
      expect(printed, contains('Grants:   view_sessions, approve'));
      expect(printed, contains('Address:  box.example.com:$port'));
      expect(printed, contains('█'), reason: 'a QR drawn in blocks');

      // The payload is a host invite naming where to dial, with the code.
      final lines = printed.split('\n');
      final invite = HostPairingInvite.decode(
        lines[lines.indexWhere((l) => l.startsWith('Payload')) + 1],
      );
      expect(invite.endpoint, 'box.example.com:$port');
      expect(invite.code, code);
      expect(invite.route, HostRoute.direct);

      // The phone's own pairing client, typing the code — at loopback, where
      // this test's server listens.
      final transport = LanTransport(host: '127.0.0.1', port: port)..start();
      final paired =
          await CompanionPairingClient(
            store: InMemoryCompanionStore(),
            deviceName: 'Phone says',
          ).pairWithTypedCode(
            codeSecret: PairingCode.tryDecode(code)!,
            relay: Uri.parse('https://invalid.local'),
            transport: transport,
          );
      await transport.close();
      expect(
        paired.capabilities,
        CapabilitySet.of([Capability.viewSessions, Capability.approve]),
      );

      expect(await pairing, 0, reason: '${err.text}');
      expect(out.text.toString(), contains('Paired: Test phone ('));

      final listed = CapturingSink();
      expect(await runDevices(const [], out: listed, paths: server.paths), 0);
      expect(listed.text.toString(), contains('Test phone'));
      expect(listed.text.toString(), contains('active'));
      expect(
        listed.text.toString(),
        contains('2 of ${Capability.values.length}'),
      );

      final deviceId = RegExp(
        r'^([0-9a-f]{8,})\s+Test phone',
        multiLine: true,
      ).firstMatch(listed.text.toString())!.group(1)!;
      final revoked = CapturingSink();
      expect(
        await runRevoke(
          [deviceId.substring(0, 6)],
          out: revoked,
          paths: server.paths,
        ),
        0,
      );
      expect(revoked.text.toString(), contains('revoked Test phone'));

      await server.stop();
      final db = AppDatabase.open(Directory(dataDir));
      addTearDown(db.close);
      final row = PairedDeviceDao(db).getById(deviceId)!;
      expect(row.revoked, isTrue);
      expect(row.name, 'Test phone');
    });

    test('pair refuses a capability it does not know, by name', () async {
      final err = CapturingSink();
      expect(
        await runPair(
          ['--capabilities=view_sessions,fly'],
          err: err,
          paths: HostPaths(Directory(p.join(root.path, 'nobody'))),
        ),
        2,
      );
      expect(err.text.toString(), contains('unknown capability "fly"'));
    });

    test('with no server it says where it looked', () async {
      final err = CapturingSink();
      expect(
        await runPair(
          const [],
          err: err,
          paths: HostPaths(Directory(p.join(root.path, 'nobody'))),
        ),
        5,
      );
      expect(err.text.toString(), contains('no server at'));
    });
  });

  group('agent CLIs', () {
    test('a standalone server records what it finds at start, under this '
        "machine's environment, and agents --refresh probes again", () async {
      final adapter = AgentRegistry.builtIn.adapters.first;
      final binary = adapter.descriptor.binaries
          .forKind(EnvironmentKind.localPosix)
          .first;
      final runner = FakeRunner({binary: '/opt/fake/$binary'});
      final server = await InProcessServer.start(
        root,
        standalone(),
        agentsFor: (db) => ServerAgents(database: db, runner: runner),
      );
      addTearDown(server.stop);
      await server.out.saw('agents: ');
      expect(server.out.text.toString(), contains('Found 1 agent CLI (1 new)'));

      final listed = CapturingSink();
      expect(await runAgents(const [], out: listed, paths: server.paths), 0);
      expect(listed.text.toString(), contains(adapter.descriptor.displayName));
      expect(listed.text.toString(), contains('/opt/fake/$binary'));
      expect(listed.text.toString(), contains('9.9.9'));

      final again = CapturingSink();
      expect(
        await runAgents(const ['--refresh'], out: again, paths: server.paths),
        0,
      );
      expect(again.text.toString(), contains('Found 1 agent CLI.'));

      await server.stop();
      final db = AppDatabase.open(Directory(dataDir));
      addTearDown(db.close);
      final rows = db.query('SELECT * FROM agent_installations;');
      expect(rows, hasLength(1), reason: 'the second probe added no row');
      expect(rows.single['agent_kind'], adapter.id);
      expect(rows.single['version'], '9.9.9');
      final environment = db.query(
        'SELECT * FROM execution_environments WHERE id = ?;',
        [rows.single['environment_id']],
      );
      expect(environment.single['kind'], EnvironmentKind.localPosix.name);
    });

    test('a host the app starts does not probe on its own', () async {
      final runner = FakeRunner(const {});
      final server = await InProcessServer.start(root, [
        '--data-dir=$dataDir',
        '--companion-port=0',
        '--mcp-port=0',
      ], agentsFor: (db) => ServerAgents(database: db, runner: runner));
      addTearDown(server.stop);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(runner.asked, isEmpty);
    });
  });
}
