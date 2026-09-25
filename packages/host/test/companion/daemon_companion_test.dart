import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// The phone companion served by the daemon, end to end: a real companion
/// client dials the daemon's LAN listener, seals with the key a pairing row
/// holds, and asks what a phone asks. Nothing between the two ends is stubbed
/// but the PTY.
void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 7));

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late StreamController<LifecycleEvent> events;
  late DaemonCompanion companion;

  setUp(() async {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      'created_at) VALUES (?, ?, ?, ?, ?);',
      ['p1', 'Shop', 'local', '/src/shop', t0.toIso8601String()],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', t0.toIso8601String()],
    );
    PairedDeviceDao(database).insert(
      PairedDevice(
        id: 'pixel',
        name: 'Pixel',
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        generation: 0,
        createdAt: t0,
      ),
    );
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    events = StreamController<LifecycleEvent>.broadcast();
    companion = DaemonCompanion(
      database: database,
      registry: registry,
      hostName: 'desk',
      lanPort: 0,
      transcriptPollInterval: Duration.zero,
      screens: RegistryScreens(registry, enterDelay: Duration.zero),
      clock: () => t0,
    );
    await companion.start(sessionEvents: events.stream);
  });

  tearDown(() async {
    await companion.close();
    await events.close();
    // A fake child never exits on its own; the shutdown would wait out its
    // reap bound for each.
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  void insertRow(
    String id, {
    String title = 'Fix the cart',
    SessionStatus? status,
  }) => SessionDao(database).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: title,
      useWorktree: false,
      status: status ?? SessionStatus.running,
      createdAt: t0,
    ),
  );

  FakePtyHandle openHosted(
    String hostId, {
    List<String> argv = const ['claude'],
  }) {
    registry.open(
      hostId,
      PtySpawnRequest(
        argv: argv,
        workingDirectory: '/src/shop/api',
        environment: const {},
        columns: 80,
        rows: 24,
      ),
    );
    return launcher.handles.last;
  }

  Future<CompanionClient> dial() async {
    final port = companion.port!;
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: hostDeviceIdFor(database),
        deviceId: DeviceId.parse('c' * 32),
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        relay: Uri.parse('https://unused.invalid'),
        generation: 0,
        hostName: 'desk',
        directEndpoint: '127.0.0.1:$port',
      ),
      store: InMemoryCompanionStore(),
    );
    addTearDown(client.close);
    await client.connect(
      transport: LanTransport(host: '127.0.0.1', port: port)..start(),
      generation: 0,
      helloTimeout: const Duration(seconds: 10),
    );
    return client;
  }

  group('with the desktop app closed', () {
    test(
      'a phone lists the store\'s rows and the sessions the host runs',
      () async {
        insertRow('s1');
        openHosted(hostSessionIdOf('s1'));
        openHosted('box_session', argv: const ['htop']);

        final client = await dial();
        final sessions = await client.listSessions();

        final row = sessions.singleWhere((s) => s.sessionId == 's1');
        expect(row.title, 'Fix the cart');
        expect(row.status, 'running');
        expect(row.repositoryName, 'shop-api');
        expect(row.projectName, 'Shop');
        expect(row.whereabouts, 'running on desk');
        expect(
          row.attention,
          isNull,
          reason: 'attention is the app\'s status registry; the host says none',
        );
        final box = sessions.singleWhere((s) => s.sessionId == 'box_session');
        expect(
          box.title,
          'htop',
          reason: 'a session no row names is its command',
        );
        expect(
          sessions,
          hasLength(2),
          reason: 'the row\'s own session is not listed twice',
        );
      },
    );

    test('a hosted session\'s transcript is its screen', () async {
      insertRow('s1');
      final pty = openHosted(hostSessionIdOf('s1'));
      pty.emit(utf8.encode('Claude is thinking\r\n> '));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final client = await dial();
      final page = await client.transcript('s1');

      expect(page.messages, hasLength(1));
      expect(page.messages.single.role, 'agent');
      expect(page.messages.single.text, 'Claude is thinking\n>');
    });

    test(
      'a session the host holds no screen for says there is no chat view',
      () async {
        insertRow('gone', status: SessionStatus.completed);

        final client = await dial();
        final page = await client.transcript('gone');

        expect(page.messages, isEmpty);
        expect(page.absence, RemoteTranscriptAbsence.noChatView);
      },
    );

    test('a prompt is typed into the hosted session, then Enter', () async {
      insertRow('s1');
      // Nobody holds the write token: the app's pane hung up with the app.
      final pty = openHosted(hostSessionIdOf('s1'));

      final client = await dial();
      final delivery = await client.sendPrompt('s1', 'run the tests');

      expect(delivery, RemotePromptDelivery.sent);
      expect(
        [for (final write in pty.writes) utf8.decode(write)],
        ['run the tests', '\r'],
      );
      expect(
        registry.find(hostSessionIdOf('s1'))!.token.isHeld,
        isFalse,
        reason: 'the token is let go, so a pane that attaches can drive',
      );
    });

    test(
      'a prompt to a session somebody is driving is refused by name',
      () async {
        insertRow('s1');
        openHosted(hostSessionIdOf('s1'));
        registry.find(hostSessionIdOf('s1'))!.token.claim('laptop-pane', t0);

        final client = await dial();

        await expectLater(
          client.sendPrompt('s1', 'hello'),
          throwsA(
            isA<RemoteApiException>().having(
              (e) => e.message,
              'message',
              contains('laptop-pane'),
            ),
          ),
        );
      },
    );

    test('notes and todos come from the store', () async {
      NoteDao(database).insert(
        Note(
          id: 'n1',
          body: 'Try a compact tab strip',
          projectId: 'p1',
          createdAt: t0,
          updatedAt: t0,
        ),
      );
      TodoDao(database).insert(
        Todo(id: 't1', body: 'Ship the fix', position: 0, createdAt: t0),
      );

      final client = await dial();
      final notes = await client.notes();

      expect(notes.notesEnabled, isTrue);
      expect(notes.notes.single.body, 'Try a compact tab strip');
      expect(notes.notes.single.projectName, 'Shop');
      expect(notes.todos.single.body, 'Ship the fix');
    });

    test('what only the app can do says the app is not running', () async {
      final client = await dial();

      await expectLater(
        client.listProjects(),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.message,
            'message',
            kCompanionAppNotRunning,
          ),
        ),
      );
      await expectLater(
        client.startSession(
          requestId: 'r-1',
          repositoryId: 'r1',
          installationId: 'a1',
          permissionMode: 'default',
        ),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.message,
            'message',
            kCompanionAppNotRunning,
          ),
        ),
      );
    });

    test(
      'the app arriving and leaving mid-sweep fails the sweep quietly',
      () async {
        insertRow('s1');
        final client = await dial();
        // A request makes the phone live, so the app's arrival re-sweeps it.
        await client.listSessions();

        final app = Object();
        final calls = <CompanionCallMessage>[];
        await companion.adopt(
          app,
          const CompanionConfig(enabled: true).toJson(),
          (message) {
            if (message is CompanionCallMessage) calls.add(message);
          },
        );
        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(calls.single.method, CompanionMethod.listSessions.wire);

        // Unanswered, then gone: the sweep's call fails. Escaping, that error
        // is uncaught — which fails this test, and in the daemon ends the
        // process with every session it holds.
        await companion.detach(app);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final after = await client.listSessions();
        expect(after.single.sessionId, 's1', reason: 'from the store again');
      },
    );

    test('a push token is kept in the store', () async {
      final client = await dial();
      await client.registerNotifications(token: 'fcm-1', platform: 'android');

      expect(PairedDeviceDao(database).getById('pixel')!.pushToken, 'fcm-1');
    });
  });

  group('with the desktop app connected', () {
    final app = Object();
    late List<CompanionCallMessage> calls;

    setUp(() async {
      calls = [];
      await companion.adopt(
        app,
        const CompanionConfig(enabled: true).toJson(),
        (message) {
          if (message is CompanionCallMessage) calls.add(message);
        },
      );
    });

    test('the session list is the app\'s', () async {
      insertRow('s1');
      final client = await dial();
      final listing = client.listSessions();
      while (calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final call = calls.first;
      expect(call.method, CompanionMethod.listSessions.wire);
      companion.answer(
        app,
        CompanionResultMessage.success(call.callId, {
          'sessions': [
            const RemoteSessionSnapshot(
              sessionId: 's1',
              title: 'Fix the cart',
              status: 'running',
              attention: kAttentionNeedsApproval,
            ).toJson(),
          ],
        }),
      );
      // The stage of each row is asked of the app too.
      while (calls.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      companion.answer(
        app,
        CompanionResultMessage.success(calls[1].callId, {'stage': null}),
      );

      final sessions = await listing;
      expect(sessions.single.attention, kAttentionNeedsApproval);
    });

    test('an app refusal reaches the phone in the app\'s words', () async {
      final client = await dial();
      final listing = client.listProjects();
      while (calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      companion.answer(
        app,
        CompanionResultMessage.failure(
          calls.first.callId,
          code: ErrorCode.badRequest.wire,
          message: 'no projects here',
        ),
      );

      await expectLater(
        listing,
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.message,
            'message',
            'no projects here',
          ),
        ),
      );
    });

    test(
      'news from the app returns before the app answers what it asks',
      () async {
        final client = await dial();
        // A phone that listed sessions, and so is swept for new ones.
        final listing = client.listSessions();
        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        companion.answer(
          app,
          CompanionResultMessage.success(calls.first.callId, {'sessions': []}),
        );
        await listing;
        calls.clear();

        // The host server reads the app's next frame — the answer the re-sweep
        // waits for — only once this returns; awaiting the sweep here is a
        // link that never reads again.
        await companion
            .notice(
              app,
              const CompanionNoticeMessage(CompanionNoticeKind.sessionsMoved),
            )
            .timeout(const Duration(seconds: 2));

        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(calls.first.method, CompanionMethod.listSessions.wire);
        companion.answer(
          app,
          CompanionResultMessage.success(calls.first.callId, {'sessions': []}),
        );
      },
    );

    test(
      'the app leaving mid-call fails that call, and the host answers after',
      () async {
        insertRow('s1');
        final client = await dial();
        final listing = client.listSessions();
        while (calls.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        await companion.detach(app);

        await expectLater(listing, throwsA(isA<RemoteApiException>()));
        final after = await client.listSessions();
        expect(after.single.sessionId, 's1', reason: 'from the store now');
      },
    );
  });

  group('settings', () {
    test('what the app sent is kept, without its own relay', () async {
      await companion.adopt(
        Object(),
        CompanionConfig(
          enabled: true,
          relay: Uri.parse('wss://relay.example.com'),
          localRelayUrl: Uri.parse('ws://192.168.1.4:8787'),
          notesEnabled: false,
        ).toJson(),
        (_) {},
      );

      final kept = CompanionConfigStore(database).read()!;
      expect(kept.relay, Uri.parse('wss://relay.example.com'));
      expect(kept.localRelayUrl, isNull);
      expect(kept.notesEnabled, isFalse);
    });

    test('remote access switched off stops listening', () async {
      expect(companion.service, isNotNull);

      await companion.adopt(
        Object(),
        const CompanionConfig(enabled: false).toJson(),
        (_) {},
      );

      expect(companion.service, isNull);
      expect(companion.port, isNull);
    });

    test('a pairing with no relay anywhere is direct and says so', () async {
      final window = await companion.openPairing(
        capabilities: CapabilitySet.all.bits,
        relay: '',
        relayIsLocal: false,
      );

      expect(window.code, isNotEmpty);
      expect(window.payload, isNotEmpty);
      final ended = expectLater(window.paired, throwsA(anything));
      await companion.notice(
        Object(),
        const CompanionNoticeMessage(CompanionNoticeKind.pairingCancelled),
      );
      await ended;
    });
  });
}
