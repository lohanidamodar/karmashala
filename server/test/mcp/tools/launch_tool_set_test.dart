import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/mcp/tools/launch_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `open_new_session` with no app open: started by the server in its own
/// environment, recorded as the caller's child, under the same caps the app
/// applied — and the app's own when it is open.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late ServerToolContext context;
  late bool appConnected;
  late LaunchToolSet tools;
  var ids = 0;

  setUp(() {
    ids = 0;
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?), (?, ?, ?, ?);',
      [
        'local', Platform.isWindows ? 'windowsNative' : 'localPosix', 'Here',
        t0.toIso8601String(), //
        'wsl1', 'wsl', 'Ubuntu', t0.toIso8601String(),
      ],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0', //
        'r2', 'p2', 'far', 'wsl1', '/home/u/far', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1, //
        'a2', AgentIds.claudeCode, 'wsl1', '/usr/bin/claude', '$t0', 1,
      ],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    context = ServerToolContext(
      database: database,
      data: DataService(database, clock: () => t0),
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    appConnected = false;
    final launcher = HostedAgentLauncher(
      registry: registry,
      sessions: SessionDao(database),
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
      now: () => t0,
      newId: () => 'new-${++ids}',
      hostEnvironment: const {},
    );
    tools = LaunchToolSet(
      context,
      appConnected: () => appConnected,
      launcher: () => launcher,
    );
  });

  tearDown(() async {
    context.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  Session insertCaller(String id, {String? parent, String? mode}) {
    final row = Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Orchestrator $id',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: t0,
      parentSessionId: parent,
      parentLink: parent == null ? null : SessionLink.spawn,
      permissionMode: mode,
    );
    SessionDao(database).insert(row);
    return row;
  }

  test('with the app open, the tool is the app\'s', () {
    appConnected = true;
    expect(tools.call('open_new_session', {'projectId': 'p1'}, null), isNull);
  });

  test('starts the agent here as the caller\'s child, the prompt under the '
      'caller\'s name', () async {
    insertCaller('caller');
    final answer =
        (await tools.call('open_new_session', {
              'projectId': 'p1',
              'title': 'Write the tests',
              'prompt': 'add a test for the cart',
            }, 'caller')!)
            as Map<String, Object?>;

    expect(answer['sessionId'], 'new-1');
    expect(answer['depth'], 1);
    final row = SessionDao(database).getById('new-1')!;
    expect(row.parentSessionId, 'caller');
    expect(row.parentLink, SessionLink.spawn);
    expect(row.title, 'Write the tests');
    expect(registry.find('karmashala_new-1'), isNotNull);
    final argv = pty.started.last.argv.join(' ');
    expect(
      argv,
      contains(
        '[message from the Karmashala session "Orchestrator caller" (caller)]',
      ),
    );
  });

  test('refuses past the spawn depth, nothing started', () async {
    insertCaller('root');
    insertCaller('child', parent: 'root');
    insertCaller('grandchild', parent: 'child');
    await expectLater(
      tools.call('open_new_session', {'projectId': 'p1'}, 'grandchild'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('levels deep'),
        ),
      ),
    );
    expect(pty.started, isEmpty);
  });

  test('refuses a named mode above the spawn ceiling', () async {
    insertCaller('caller');
    await expectLater(
      tools.call('open_new_session', {
        'projectId': 'p1',
        'permissionMode': 'bypass',
      }, 'caller'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a checkout only the app reaches is refused in words', () async {
    await expectLater(
      tools.call('open_new_session', {
        'projectId': 'p2',
      }, null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('only the Karmashala app starts agents there'),
        ),
      ),
    );
  });

  test('a cli nobody installed here is refused', () async {
    await expectLater(
      tools.call('open_new_session', {'projectId': 'p1', 'cli': 'codex'}, null),
      throwsA(isA<StateError>()),
    );
  });
}
