import 'dart:async';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'pipe_connection.dart';

Future<void> pump() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const request = PtySpawnRequest(argv: ['/bin/sh'], columns: 80, rows: 24);
final clock = DateTime.utc(2026, 9, 25, 10, 0);

void main() {
  late AppDatabase db;
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late HostServer server;
  late SessionStatusRecording recording;
  late List<String> written;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    final now = clock.toIso8601String();
    for (final (id, kind) in [('win', 'windowsNative'), ('ssh:h1', 'ssh')]) {
      db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        'VALUES (?, ?, ?, ?);',
        [id, kind, id, now],
      );
    }
    for (final (id, env) in [('local', 'win'), ('remote', 'ssh:h1')]) {
      db.execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [id, 'p1', id, env, '/src/$id', now],
      );
    }
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, clock: () => clock);
    server = HostServer(
      registry: registry,
      ptyLibrary: 'libc.so.6',
      clock: () => clock,
    );
    written = [];
    recording = SessionStatusRecording(
      server.lifecycle,
      db,
      clock: () => clock,
      // What the data service tells every client: the row as it now stands.
      onWritten: (id) => written.add(
        '$id ${db.query('SELECT status FROM sessions WHERE id = ?;', [id]).single['status']}',
      ),
    );
  });
  tearDown(() async {
    await recording.close();
    db.close();
  });

  void row(String id, String status, {String repositoryId = 'local'}) =>
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        'title, use_worktree, status, created_at) '
        'VALUES (?, ?, ?, ?, 0, ?, ?);',
        [id, repositoryId, 'a1', 'Work', status, clock.toIso8601String()],
      );

  String statusOf(String id) =>
      db.query('SELECT status FROM sessions WHERE id = ?;', [
            id,
          ]).single['status']!
          as String;

  Future<HostLifecycleWatch> watch({List<String> runByClient = const []}) {
    final (client, host) = PipeEnd.pair();
    unawaited(server.serveConnection(host));
    return HostLifecycleWatch.over(
      client,
      clientId: 'app',
      runByClient: runByClient,
    );
  }

  test('on start, the sessions it holds are written to their rows', () {
    row('s1', 'unknown');
    row('s2', 'running');
    registry.open('karmashala_s1', request);
    final done = registry.open('karmashala_s2', request);
    launcher.handles.last.finish(1);

    return done.ended.then((_) async {
      await pump();
      recording.start();
      expect(statusOf('s1'), 'running');
      expect(statusOf('s2'), 'failed');
    });
  });

  test('each event is written, and each row written is handed on to be told '
      'on the data channel', () async {
    row('s1', 'running');
    recording.start();
    final feed = await watch();
    final said = <String>[];
    feed.events.listen((e) => said.add('lifecycle ${e.kind.name}'));

    registry.open('karmashala_s1', request);
    launcher.handles.last.finish(0);
    await pump();

    expect(statusOf('s1'), 'completed');
    expect(said, ['lifecycle started', 'lifecycle exited']);
    expect(written, [
      // Watched before the pane opened: nobody held it yet.
      's1 unknown',
      's1 running',
      's1 completed',
    ]);
    await feed.close();
  });

  test('a watch marks the live rows on this machine it does not hold unknown, '
      'and says so to that watcher', () async {
    row('held', 'running');
    row('lost', 'running');
    row('in-app', 'running');
    row('remote', 'running', repositoryId: 'remote');
    row('done', 'completed');
    registry.open('karmashala_held', request);
    recording.start();

    written.clear();
    final feed = await watch(runByClient: ['in-app']);
    await pump();

    expect(written, ['lost unknown']);
    expect(statusOf('held'), 'running');
    expect(statusOf('in-app'), 'running');
    expect(statusOf('remote'), 'running', reason: 'an SSH host speaks for it');
    expect(statusOf('done'), 'completed');
    await feed.close();
  });

  test('without a recording, a host writes nothing and still feeds', () async {
    row('s1', 'running');
    final feed = await watch();
    registry.open('karmashala_s1', request);
    launcher.handles.last.finish(0);
    await pump();
    expect(statusOf('s1'), 'running');
    await feed.close();
  });
}
