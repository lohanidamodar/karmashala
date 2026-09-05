import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_app_servers.dart';
import 'package:karmashala/src/features/cli_detection/domain/detected_session.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fake_codex_app_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// **Where a Codex rename actually has to land.**
///
/// `<codexHome>/session_index.jsonl` is a mirror Codex writes and never reads —
/// a sentinel planted in it under a scratch `CODEX_HOME` was ignored by
/// `thread/list` and left untouched on disk, while a sentinel planted in
/// `state_5.sqlite`'s `threads.name` came straight back. So the rewrite this
/// app used to do looked right locally and never reached Codex, which is the
/// bug these cases pin shut.
///
/// Nothing here runs `codex`: the app-server is a [FakeCodexAppServer] behind a
/// [FakeCommandRunner], which also lets the *command line* be asserted — the
/// half a scripted transport alone would not cover.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late CliSessionMutator mutator;
  late FakeCodexAppServer server;
  late FakeCommandRunner runner;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_codex_rename_');
    db = AppDatabase(sqlite3.openInMemory());
    mutator = CliSessionMutator();
    server = FakeCodexAppServer(codexHome: p.join(tmp.path, '.codex'));
    runner = FakeCommandRunner(processFactory: (_) => server);
  });
  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  /// A store with one already-named entry in its mirror, and the session for it.
  DetectedSession seedStore({String environmentId = 'windows'}) {
    File(p.join(tmp.path, '.codex/session_index.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode({
          'id': 'u1',
          'thread_name': 'old',
          'updated_at': '2020-01-01T00:00:00.000Z',
        })}\n',
      );
    final rollout = File(p.join(tmp.path, '.codex/sessions/rollout-x-u1.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}\n');
    return DetectedSession(
      cli: AgentIds.codex,
      sessionId: 'u1',
      cwd: EnvironmentPath(environmentId: environmentId, path: '/x'),
      filePath: rollout.path,
      storeHome: p.join(tmp.path, '.codex'),
    );
  }

  CodexAppServers servers({bool codexInstalled = true}) {
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    if (codexInstalled) {
      AgentInstallationDao(db).insert(
        agentInstallation(
          agentId: AgentIds.codex,
          path: r'C:\Users\me\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe',
        ),
      );
    }
    return CodexAppServers(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environments: ExecutionEnvironmentDao(db),
      installations: AgentInstallationDao(db),
    );
  }

  String mirror(DetectedSession session) =>
      File(p.join(session.storeHome, 'session_index.jsonl')).readAsStringSync();

  test('a rename asks Codex itself, and leaves the mirror to Codex', () async {
    final session = seedStore();
    final pool = servers();
    addTearDown(pool.closeAll);

    await mutator.rename(session, 'new name', codex: pool);

    expect(server.lastNameSet, {'threadId': 'u1', 'name': 'new name'});
    expect(
      mirror(session),
      isNot(contains('new name')),
      reason:
          'a protocol rename appends its own mirror line; writing one here as '
          'well is the write Codex ignores and then overwrites',
    );
  });

  test('it starts the app-server the way Codex documents it', () async {
    final pool = servers();
    addTearDown(pool.closeAll);

    await mutator.rename(seedStore(), 'new name', codex: pool);

    expect(runner.startRequests, hasLength(1));
    final request = runner.startRequests.single;
    expect(request.executable, endsWith('codex.exe'));
    expect(request.arguments, ['app-server', '--listen', 'stdio://']);
  });

  test('two renames share one app-server', () async {
    final session = seedStore();
    final pool = servers();
    addTearDown(pool.closeAll);

    await mutator.rename(session, 'first', codex: pool);
    await mutator.rename(session, 'second', codex: pool);

    expect(runner.startRequests, hasLength(1));
    expect(pool.openConnections, 1);
    expect(server.lastNameSet, {'threadId': 'u1', 'name': 'second'});
  });

  test('closing the pool leaves no app-server running', () async {
    final pool = servers();
    await mutator.rename(seedStore(), 'new name', codex: pool);

    await pool.closeAll();

    expect(server.killed, isTrue);
    expect(pool.openConnections, 0);
  });

  group('a Codex that cannot be reached', () {
    test('does not throw, and keeps our own view of the name', () async {
      final session = seedStore();
      // No Codex installation in this environment, so there is nothing to ask.
      final pool = servers(codexInstalled: false);
      addTearDown(pool.closeAll);

      await mutator.rename(session, 'new name', codex: pool);

      expect(runner.startRequests, isEmpty);
      expect(mirror(session), contains('"thread_name":"new name"'));
    });

    test('nor when the app-server refuses the call', () async {
      final session = seedStore();
      server = FakeCodexAppServer(
        reply: (server, id, method, params) => jsonEncode({
          'id': id,
          'error': {'code': -32600, 'message': 'no rollout found for thread id'},
        }),
      );
      runner = FakeCommandRunner(processFactory: (_) => server);
      final pool = servers();
      addTearDown(pool.closeAll);

      await mutator.rename(session, 'new name', codex: pool);

      expect(mirror(session), contains('"thread_name":"new name"'));
    });

    test('nor when the process cannot be started at all', () async {
      final session = seedStore();
      runner = FakeCommandRunner(
        throwError: const ProcessException('codex.exe', ['app-server']),
      );
      final pool = servers();
      addTearDown(pool.closeAll);

      await mutator.rename(session, 'new name', codex: pool);

      expect(mirror(session), contains('"thread_name":"new name"'));
    });

    test('and a caller with no pool at all still renames locally', () async {
      final session = seedStore();

      await mutator.rename(session, 'new name');

      expect(mirror(session), contains('"thread_name":"new name"'));
    });
  });

  group('the mirror this falls back on', () {
    test('is stamped now, not with the time it last held', () async {
      final session = seedStore();

      await mutator.rename(session, 'new name');

      final entry =
          jsonDecode(mirror(session).trim()) as Map<String, dynamic>;
      expect(
        entry['updated_at'],
        isNot('2020-01-01T00:00:00.000Z'),
        reason:
            'rewriting a line while keeping its old stamp falsifies the name '
            'history Codex records',
      );
      expect(DateTime.parse(entry['updated_at'] as String).isUtc, isTrue);
    });

    test('stamps an entry it has to add, too', () async {
      final session = seedStore();
      File(p.join(session.storeHome, 'session_index.jsonl')).writeAsStringSync(
        '${jsonEncode({'id': 'someone-else'})}\n',
      );

      await mutator.rename(session, 'new name');

      final lines = mirror(session).trim().split('\n');
      expect(lines, hasLength(2));
      final added = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(added['id'], 'u1');
      expect(added['thread_name'], 'new name');
      expect(added['updated_at'], isNotNull);
    });

    test('touches only the newest line for the thread', () async {
      final session = seedStore();
      final index = File(p.join(session.storeHome, 'session_index.jsonl'));
      index.writeAsStringSync(
        [
          jsonEncode({
            'id': 'u1',
            'thread_name': 'first',
            'updated_at': '2020-01-01T00:00:00.000Z',
          }),
          jsonEncode({
            'id': 'u1',
            'thread_name': 'second',
            'updated_at': '2021-01-01T00:00:00.000Z',
          }),
        ].join('\n'),
      );

      await mutator.rename(session, 'third');

      final lines = index.readAsStringSync().trim().split('\n');
      expect(
        jsonDecode(lines.first),
        containsPair('thread_name', 'first'),
        reason: 'the history is what happened; only the head is the name now',
      );
      expect(jsonDecode(lines.last), containsPair('thread_name', 'third'));
    });
  });

  test('a WSL store is asked for in the distribution own spelling', () async {
    final windows = windowsEnv();
    final wsl = wslEnv();
    ExecutionEnvironmentDao(db)
      ..upsert(windows)
      ..upsert(wsl);
    AgentInstallationDao(db).insert(
      agentInstallation(
        agentId: AgentIds.codex,
        environmentId: wsl.id,
        path: '/home/me/.local/bin/codex',
      ),
    );
    // What `initialize` reports from inside the distribution — a POSIX path,
    // never the UNC form this host reaches the same directory by.
    server = FakeCodexAppServer(codexHome: '/home/me/.codex');
    runner = FakeCommandRunner(environmentId: wsl.id, processFactory: (_) => server);
    final pool = CodexAppServers(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environments: ExecutionEnvironmentDao(db),
      installations: AgentInstallationDao(db),
    );
    addTearDown(pool.closeAll);

    final client = pool.forEnvironment(
      wsl.id,
      storeHome: r'\\wsl.localhost\Ubuntu\home\me\.codex',
    );

    expect(client, isNotNull);
    expect(client!.expectedCodexHome, '/home/me/.codex');
    expect((await client.setThreadName('u1', 'new name')).ok, isTrue);
  });
}
