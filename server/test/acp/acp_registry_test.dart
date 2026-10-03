import 'dart:async';
import 'dart:io';

import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_host/src/domain/hosted_process.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../protocol/host_server_test.dart' show PipeConnection;
import '../serve/pipe_connection.dart';
import 'acp_fixture.dart';

/// The registry holds a PTY and an ACP runtime alike (design C4): the
/// lifecycle feed, the status recording and a close work for both; a
/// terminal attach to an ACP session is refused in words.
void main() {
  final clock = DateTime.utc(2026, 10, 2, 10);
  const ptyRequest = PtySpawnRequest(argv: ['/bin/sh'], columns: 80, rows: 24);

  late AppDatabase db;
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late Directory temp;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['win', 'windowsNative', 'win', clock.toIso8601String()],
    );
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['local', 'p1', 'local', 'win', '/src/local', clock.toIso8601String()],
    );
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, clock: () => clock);
    temp = Directory.systemTemp.createTempSync('acp_registry_test');
  });

  tearDown(() async {
    await registry.shutdown();
    db.close();
    temp.deleteSync(recursive: true);
  });

  void row(String id, String status) => db.execute(
    'INSERT INTO sessions (id, repository_id, agent_installation_id, '
    'title, use_worktree, status, created_at) '
    'VALUES (?, ?, ?, ?, 0, ?, ?);',
    [id, 'local', 'a1', 'Work', status, clock.toIso8601String()],
  );

  String statusOf(String id) =>
      db.query('SELECT status FROM sessions WHERE id = ?;', [
            id,
          ]).single['status']!
          as String;

  test('both kinds are processes; only the PTY is a session a pane finds, '
      'and attaching to the ACP one is refused in words', () async {
    final pty = registry.open('karmashala_p', ptyRequest);
    final process = FakeAcpProcess(FakeAcpAgent());
    final runtime = registry.openAcp(
      'karmashala_a',
      runtimeOver(
        process,
        database: db,
        workingDirectory: temp.path,
        sessionId: 'a',
      ),
    );
    await runtime.start();

    expect(registry.processes.map((p) => p.id), [
      'karmashala_p',
      'karmashala_a',
    ]);
    expect(registry.sessions.map((s) => s.id), ['karmashala_p']);
    expect(registry.screens.map((s) => s.id), ['karmashala_p', 'karmashala_a']);
    expect(registry.find('karmashala_p'), same(pty));
    expect(registry.find('karmashala_a'), isNull);
    expect(registry.findAcp('karmashala_a'), same(runtime));
    expect(registry.findAcp('karmashala_p'), isNull);
    expect(registry.findProcess('karmashala_a'), isA<AcpProcess>());
    expect(registry.findProcess('karmashala_p'), isA<PtyProcess>());
    expect(registry.list().map((s) => s.id), ['karmashala_p']);
    expect(
      () => registry.require('karmashala_a'),
      throwsA(
        isA<SessionHasNoTerminal>().having(
          (e) => e.toString(),
          'words',
          contains('no terminal to attach to'),
        ),
      ),
    );
    expect(() => registry.require('nope'), throwsA(isA<UnknownSession>()));
    expect(
      () => registry.openAcp(
        'karmashala_a',
        runtimeOver(process, database: db, workingDirectory: temp.path),
      ),
      throwsA(isA<SessionAlreadyExists>()),
    );
    launcher.handles.last.finish(0);
  });

  test('a client attaching to an ACP session is told why it cannot', () async {
    final process = FakeAcpProcess(FakeAcpAgent());
    final runtime = registry.openAcp(
      'karmashala_a',
      runtimeOver(
        process,
        database: db,
        workingDirectory: temp.path,
        sessionId: 'a',
      ),
    );
    await runtime.start();
    final server = HostServer(
      registry: registry,
      ptyLibrary: 'libc.so.6',
      clock: () => clock,
    );
    final client = PipeConnection('pane');
    unawaited(server.serveConnection(client));
    await client.send(const HelloMessage(requestId: 1, clientId: 'pane'));
    await client.send(
      const AttachMessage(
        requestId: 2,
        sessionId: 'karmashala_a',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    final refused = client.last<ErrorMessage>();
    expect(refused.requestId, 2);
    expect(refused.code, ProtocolErrorCode.unknownSession);
    expect(refused.message, contains('no terminal to attach to'));
    expect(client.all<AttachedMessage>(), isEmpty);
  });

  test('the lifecycle feed reports an ACP runtime started, exited and closed, '
      'and the recording writes its row', () async {
    row('a', 'running');
    final server = HostServer(
      registry: registry,
      ptyLibrary: 'libc.so.6',
      clock: () => clock,
    );
    final recording = SessionStatusRecording(
      server.lifecycle,
      db,
      clock: () => clock,
    )..start();
    final (client, host) = PipeEnd.pair();
    unawaited(server.serveConnection(host));
    final feed = await HostLifecycleWatch.over(client, clientId: 'app');
    final said = <String>[];
    feed.events.listen((e) => said.add('${e.sessionId} ${e.kind.name}'));

    final process = FakeAcpProcess(FakeAcpAgent());
    final runtime = registry.openAcp(
      'karmashala_a',
      runtimeOver(
        process,
        database: db,
        workingDirectory: temp.path,
        sessionId: 'a',
      ),
    );
    await runtime.start();
    await pump();
    expect(statusOf('a'), 'running');
    expect(said, ['karmashala_a started']);

    await process.die(2);
    await runtime.ended;
    await pump();
    expect(said, ['karmashala_a started', 'karmashala_a exited']);
    expect(statusOf('a'), 'failed');
    final facts = server.lifecycle.snapshot().single;
    expect(facts.state, HostSessionState.exited);
    expect(facts.exitCode, 2);
    await feed.close();
    await recording.close();
  });

  test(
    'closing an ACP session stops its runtime and is told as a close',
    () async {
      row('a', 'running');
      final server = HostServer(
        registry: registry,
        ptyLibrary: 'libc.so.6',
        clock: () => clock,
      );
      final recording = SessionStatusRecording(
        server.lifecycle,
        db,
        clock: () => clock,
      )..start();
      final changes = <RegistryChange>[];
      registry.changes.listen(changes.add);
      final process = FakeAcpProcess(
        FakeAcpAgent(
          turns: const [
            FakeTurn([FakeStep.waitForCancel()]),
          ],
        ),
      );
      final runtime = registry.openAcp(
        'karmashala_a',
        runtimeOver(
          process,
          database: db,
          workingDirectory: temp.path,
          sessionId: 'a',
        ),
      );
      await runtime.start();
      await runtime.send('Go');
      await pump();

      final end = await registry.close('karmashala_a');
      expect(end.hasEnded, isTrue);
      expect(process.killed, isTrue);
      expect(process.agent.cancels, 1);
      expect(registry.findProcess('karmashala_a'), isNull);
      expect(
        changes.last,
        isA<SessionClosed>().having((c) => c.endedByClose, 'byClose', true),
      );
      await pump();
      final closed = server.lifecycle.snapshot().single;
      expect(closed.state, HostSessionState.closed);
      expect(closed.endedByClose, isTrue);
      // A close on request is the person stopping it, as a PTY's is recorded.
      expect(statusOf('a'), 'cancelled');
      await recording.close();
    },
  );

  test('shutdown stops an ACP runtime as the host\'s doing', () async {
    final process = FakeAcpProcess(FakeAcpAgent());
    final runtime = registry.openAcp(
      'karmashala_a',
      runtimeOver(
        process,
        database: db,
        workingDirectory: temp.path,
        sessionId: 'a',
      ),
    );
    await runtime.start();
    await registry.shutdown();
    expect(
      runtime.lifecycle,
      isA<SessionEndedWithoutCode>().having(
        (e) => e.reason,
        'reason',
        SessionEndedWithoutCode.hostStopped,
      ),
    );
  });
}
