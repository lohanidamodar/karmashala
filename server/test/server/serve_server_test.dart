/// `serve` — one server, one way — in this process on temp directories: its
/// store (created, or the one the desktop app migrated, or refused when
/// newer), its data directory by default, its config (read, and changed live
/// over `server.config.set`), pairing, devices and revoke from the CLI, and
/// the agent CLIs it records.
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/process.dart'
    show EnvironmentKind, EnvironmentPath, localHostEnvironmentId;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/values.dart' show WriteExpectation;
import 'package:karmashala_host/data.dart' show HostDataLink;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show HostLifecycleWatch, HostLifecycleWatchRefused;
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

  List<String> serveArgs([List<String> more = const []]) => [
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
      final server = await InProcessServer.start(root, serveArgs());
      addTearDown(server.stop);
      expect(
        server.out.text.toString(),
        contains('server "${Platform.localHostname}", data in $dataDir'),
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

      final server = await InProcessServer.start(root, serveArgs());
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
          serveArgs(),
          environment: scratchEnvironment(root),
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

    test('with no --data-dir it is ~/.karmashala: store created and '
        'migrated there, config read there', () async {
      final home = Directory(p.join(root.path, 'home'))..createSync();
      final data = p.join(home.path, '.karmashala');
      await const ServerConfig(name: 'from-home').write(data);
      final serve = await Process.start(
        Platform.resolvedExecutable,
        [
          'bin/karmashala_host.dart',
          'serve',
          '--companion-port=0',
          '--mcp-port=0',
        ],
        environment: {
          'HOME': home.path,
          kHostDirectoryEnvironmentVariable: p.join(root.path, 'host'),
        },
      );
      final said = StringBuffer();
      final greeted = Completer<void>();
      serve.stdout.transform(const SystemEncoding().decoder).listen((text) {
        said.write(text);
        if (said.toString().contains('restored ') && !greeted.isCompleted) {
          greeted.complete();
        }
      });
      final errors = StringBuffer();
      serve.stderr
          .transform(const SystemEncoding().decoder)
          .listen(errors.write);
      await Future.any([
        greeted.future,
        serve.exitCode.then((code) => fail('serve exited $code: $errors')),
      ]).timeout(const Duration(minutes: 2));
      expect('$said', contains('server "from-home", data in $data'));
      expect('$said', contains('store ${p.join(data, kStoreFileName)}'));
      serve.kill(ProcessSignal.sigterm);
      expect(await serve.exitCode, 0, reason: '$errors');

      final expected = AppDatabase.memory();
      addTearDown(expected.close);
      expect(userVersion(data), expected.schemaVersion);
      expect(Directory(data).statSync().mode & 0x1ff, 0x1c0);
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

      final server = await InProcessServer.start(root, serveArgs());
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
      final first = await InProcessServer.start(root, serveArgs());
      addTearDown(first.stop);
      // A process of its own: the lock is a POSIX record lock, which never
      // conflicts with its own process.
      final second = await Process.run(
        Platform.resolvedExecutable,
        [
          'bin/karmashala_host.dart',
          'serve',
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
        serveArgs(['--name=from-flag', '--companion']),
      );
      addTearDown(server.stop);
      final said = server.out.text.toString();
      expect(said, contains('server "from-flag"'));
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
        serveArgs(),
        environment: scratchEnvironment(root),
        out: CapturingSink(),
        err: err,
        paths: HostPaths(hostDir),
        agentsFor: noAgents,
      );
      expect(code, 2);
      expect(err.text.toString(), contains('not an IP address'));
      expect(hostDir.existsSync(), isFalse);
    });

    test('a fresh server serves no phones until its config says so', () async {
      final server = await InProcessServer.start(root, serveArgs());
      addTearDown(server.stop);
      expect(server.out.text.toString(), contains('companion off'));
    });

    test('server.config.get and set round-trip over the socket: the file is '
        'written owner-only, its token never said back, and the phone '
        'listener follows at once', () async {
      await ServerConfig(
        companionEnabled: true,
        relay: Uri.parse('wss://relay.example.com'),
        relayToken: 'a' * 32,
      ).write(dataDir);
      final server = await InProcessServer.start(root, serveArgs());
      addTearDown(server.stop);
      final client = (await HostClient.connect(server.paths.socketPath))!;
      addTearDown(client.close);
      Future<Map<String, Object?>> served() async =>
          (await client.call(ServerMethod.serverInfo))['companion']!
              as Map<String, Object?>;

      final got = await client.call(ServerMethod.configGet);
      final file = got['file']! as Map<String, Object?>;
      final settings = got['settings']! as Map<String, Object?>;
      expect((file['companion']! as Map)['relay'], 'wss://relay.example.com');
      expect('$got', isNot(contains('a' * 32)), reason: 'never the token');
      expect((settings['companion']! as Map)['relayTokenSet'], isTrue);
      expect((settings['companion']! as Map)['bind'], '127.0.0.1');
      expect(got['flags'], containsAll(['companion.port', 'mcp.port']));
      expect((await served())['bind'], '127.0.0.1');
      expect((await served())['relay'], 'wss://relay.example.com/k/…');

      final set = await client.call(
        ServerMethod.configSet,
        arguments: {
          'patch': {
            'companion': {
              'bind': '0.0.0.0',
              'beacon': true,
              'relay': null,
              'relayToken': null,
              'extraRelays': ['ws://box.example.com:8787/k/${'b' * 32}'],
            },
          },
        },
      );
      final after = set['settings']! as Map<String, Object?>;
      expect((after['companion']! as Map)['bind'], '0.0.0.0');
      expect((await served())['bind'], '0.0.0.0');
      expect((await served())['serving'], isTrue);
      expect((await served())['relay'], isNull);

      final path = p.join(dataDir, kServerConfigFileName);
      expect(File(path).statSync().mode & 0x1ff, 0x180, reason: 'owner-only');
      final written = await ServerConfig.read(dataDir);
      expect(written.bind, '0.0.0.0');
      expect(written.beacon, isTrue);
      expect(written.relay, isNull);
      expect(written.companionEnabled, isTrue, reason: 'kept, not named');
      expect(written.extraRelays, [
        Uri.parse('ws://box.example.com:8787/k/${'b' * 32}'),
      ]);

      // Off stops the listener; the file says so for the next start too.
      await client.call(
        ServerMethod.configSet,
        arguments: {
          'patch': {
            'companion': {'enabled': false},
          },
        },
      );
      expect((await served())['serving'], isFalse);
      expect((await ServerConfig.read(dataDir)).companionEnabled, isFalse);
    });

    test('a patch that cannot be served by is refused in words, and nothing '
        'is written', () async {
      final server = await InProcessServer.start(root, serveArgs());
      addTearDown(server.stop);
      final client = (await HostClient.connect(server.paths.socketPath))!;
      addTearDown(client.close);
      await expectLater(
        client.call(
          ServerMethod.configSet,
          arguments: {
            'patch': {
              'companion': {'bind': 'everywhere'},
            },
          },
        ),
        throwsA(
          isA<HostClientRefusal>().having(
            (e) => '$e',
            'message',
            contains('not an IP address'),
          ),
        ),
      );
      expect(File(p.join(dataDir, kServerConfigFileName)).existsSync(), false);
    });

    test('the app on its lifecycle link reads and writes the config too, and '
        'its attach adds only its embedded relay', () async {
      final server = await InProcessServer.start(root, serveArgs());
      addTearDown(server.stop);
      final app = (await HostLifecycleWatch.connect(server.paths.socketPath))!;
      addTearDown(app.close);
      app.attachCompanion(localRelayUrl: 'ws://127.0.0.1:8787');

      final set = await app.serverCall(ServerMethod.configSet, {
        'patch': {
          'companion': {'enabled': true},
        },
      });
      expect(
        ((set['settings']! as Map)['companion']! as Map)['enabled'],
        isTrue,
      );
      final got = await app.serverCall(ServerMethod.configGet);
      expect(((got['file']! as Map)['companion']! as Map)['enabled'], isTrue);
      await expectLater(
        app.serverCall('server.nothing'),
        throwsA(isA<HostLifecycleWatchRefused>()),
      );
    });
  });

  group('the data API', () {
    test('a client writes a todo and a preference into the store, another '
        'is told, and a second serve reads them back', () async {
      final server = await InProcessServer.start(root, serveArgs());
      final writer = (await HostDataLink.connect(server.paths.socketPath))!;
      final reader = (await HostDataLink.connect(server.paths.socketPath))!;
      await reader.send(const DataSubscribe());
      final told = reader.changes.first;

      final todo = await writer.send(const TodoAdd(id: 't1', body: 'ship it'));
      await writer.send(const PreferenceSet('settings.v1', '{"a":1}'));
      expect(
        ((await told).changes.single as TodoChanged).todo.id,
        todo.value.id,
      );
      await writer.close();
      await reader.close();
      await server.stop();

      final again = await InProcessServer.start(root, serveArgs());
      addTearDown(again.stop);
      final client = (await HostDataLink.connect(again.paths.socketPath))!;
      addTearDown(client.close);
      expect(
        (await client.send(const TodosList())).value.single.body,
        'ship it',
      );
      expect((await client.send(const PreferencesGet())).value, {
        'settings.v1': '{"a":1}',
      });
    });
  });

  group('files (slice 3c)', () {
    test('a client reads a file bigger than a frame in chunks, a stale save '
        'is refused as a conflict, and only the watching link hears of a '
        'change', () async {
      final server = await InProcessServer.start(root, serveArgs());
      addTearDown(server.stop);
      final watcher = (await HostDataLink.connect(server.paths.socketPath))!;
      final other = (await HostDataLink.connect(server.paths.socketPath))!;
      addTearDown(watcher.close);
      addTearDown(other.close);
      await watcher.send(const DataSubscribe());
      await other.send(const DataSubscribe());
      final toOther = <DataChange>[];
      other.changes.listen((batch) => toOther.addAll(batch.changes));

      final folder = Directory(p.join(root.path, 'files'))..createSync();
      final big = File(p.join(folder.path, 'big.bin'))
        ..writeAsBytesSync(List.filled(20 * 1024 * 1024, 7));
      EnvironmentPath at(String path) =>
          EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

      final first = (await watcher.send(FilesRead(at(big.path)))).value;
      expect(first.bytes.length, kFileChunkBytes);
      expect(first.fileSize, 20 * 1024 * 1024);
      final last = (await watcher.send(
        FilesRead(at(big.path), offset: 20 * 1024 * 1024 - 5),
      )).value;
      expect(last.bytes, [7, 7, 7, 7, 7]);

      final note = File(p.join(folder.path, 'a.txt'))..writeAsStringSync('one');
      final seen = (await watcher.send(FilesStatOf(at(note.path)))).value;
      note.writeAsStringSync('someone else');
      await expectLater(
        watcher.send(
          FilesWrite(
            at(note.path),
            Uint8List.fromList(utf8.encode('mine')),
            expect: WriteExpectation.version(seen.stamp!),
          ),
        ),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.conflict,
          ),
        ),
      );
      expect(note.readAsStringSync(), 'someone else');

      await watcher.send(FilesWatch([at(folder.path)]));
      final heard = watcher.changes
          .expand((batch) => batch.changes)
          .firstWhere((change) => change is FileChanged)
          .then((change) => change as FileChanged);
      await other.send(FilesTouch(at(folder.path), 'new.txt'));
      expect(
        (await heard.timeout(const Duration(seconds: 10))).at,
        at(folder.path),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(toOther.whereType<FileChanged>(), isEmpty);
    });
  });

  group('pairing from the CLI', () {
    test('pair opens a window, prints a code, a QR and a payload that '
        'decodes, and reports the phone that paired; devices lists it and '
        'revoke revokes it', () async {
      final server = await InProcessServer.start(
        root,
        serveArgs(['--companion']),
      );
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
    test("the server records what it finds at start, under this machine's "
        'environment, and agents --refresh probes again', () async {
      final adapter = AgentRegistry.builtIn.adapters.first;
      final binary = adapter.descriptor.binaries
          .forKind(EnvironmentKind.localPosix)
          .first;
      final runner = FakeRunner({binary: '/opt/fake/$binary'});
      final server = await InProcessServer.start(
        root,
        serveArgs(),
        agentsFor: (data) => ServerAgents(data: data, runner: runner),
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

    test('the app asks for a refresh over its lifecycle link', () async {
      final adapter = AgentRegistry.builtIn.adapters.first;
      final binary = adapter.descriptor.binaries
          .forKind(EnvironmentKind.localPosix)
          .first;
      final server = await InProcessServer.start(
        root,
        serveArgs(),
        agentsFor: (data) => ServerAgents(
          data: data,
          runner: FakeRunner({binary: '/opt/fake/$binary'}),
        ),
      );
      addTearDown(server.stop);
      final app = (await HostLifecycleWatch.connect(server.paths.socketPath))!;
      addTearDown(app.close);
      final answer = await app.serverCall(ServerMethod.agentsRefresh);
      expect(answer['summary'], contains('Found 1 agent CLI'));
      expect(
        (answer['agents']! as List).single,
        containsPair('agent', adapter.id),
      );
    });
  });
}
