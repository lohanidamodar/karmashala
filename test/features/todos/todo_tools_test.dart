import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The todo tools, over the endpoint.
///
/// The half of the owner's ask that a panel cannot satisfy: *"both agent and i
/// can access easily"*. An agent that can read a plan and cannot record what is
/// left of it has to hand the remainder back through a person.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_todo_tools_');
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db)
      ..insert(project())
      ..insert(project(id: 'p2', name: 'Karmashala', path: r'C:\src\k'));
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', title: 'Fix login'));

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<({bool isError, String text, Object? structured})> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
    String? asSession,
  ]) async {
    final json =
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;
    final credential = asSession == null
        ? json['mcpToken']! as String
        : server.callers.tokenFor(asSession);
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp/$credential'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, Object?>{'name': name, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      final result =
          (jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, Object?>)['result']!
              as Map<String, Object?>;
      final content =
          (result['content']! as List<Object?>).first as Map<String, Object?>;
      return (
        isError: result['isError'] == true,
        text: content['text']! as String,
        structured: result['structuredContent'],
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Object?>> listTodos([
    Map<String, Object?> arguments = const {},
  ]) async =>
      ((await callTool('todos_list', arguments)).structured!
              as Map<String, Object?>)['todos']!
          as List<Object?>;

  test('the four todo tools are advertised to the bridge', () {
    final names = <String>[
      for (final schema in LauncherControlServer.toolSchemas)
        schema['name']! as String,
    ];
    expect(
      names,
      containsAll(['todos_list', 'todo_add', 'todo_done', 'todo_delete']),
    );
    expect(names.toSet(), hasLength(names.length));
    // Deleting one has no undo; finishing one does, which is the whole reason
    // both verbs exist.
    expect(kMcpToolAnnotations['todo_delete']!.destructive, isTrue);
    expect(kMcpToolAnnotations['todo_done']!.destructive, isFalse);
    expect(kMcpToolAnnotations['todo_done']!.idempotent, isTrue);
    expect(kMcpToolAnnotations['todos_list']!.readOnly, isTrue);
  });

  test('todo_add writes one and todos_list reads it back', () async {
    final added =
        (await callTool('todo_add', {
              'body': 'Ship the todo panel',
            })).structured!
            as Map<String, Object?>;
    expect(added['body'], 'Ship the todo panel');
    expect(added['done'], isFalse);

    final todos = await listTodos();
    expect(todos, hasLength(1));
    expect((todos.single as Map)['id'], added['id']);
  });

  test('a blank body is refused', () async {
    final result = await callTool('todo_add', {'body': '  \n '});
    expect(result.isError, isTrue);
    expect(result.text, contains('body is required'));
  });

  test('a todo from a session is filed under that session’s project', () async {
    // The convenience that makes filing happen at all: an agent working in a
    // checkout is working in exactly one project, and it should not have to
    // look up what it already knows.
    final added =
        (await callTool('todo_add', {'body': 'from s1'}, 's1')).structured!
            as Map<String, Object?>;
    expect(added['projectId'], 'p1');
  });

  test('"none" files it nowhere, and an id files it there', () async {
    final unfiled =
        (await callTool('todo_add', {
              'body': 'belongs to nothing',
              'projectId': 'none',
            }, 's1')).structured!
            as Map<String, Object?>;
    expect(
      unfiled['projectId'],
      isNull,
      reason: '"none" must beat the calling session, or it says nothing',
    );

    final elsewhere =
        (await callTool('todo_add', {
              'body': 'belongs to the other one',
              'projectId': 'p2',
            }, 's1')).structured!
            as Map<String, Object?>;
    expect(elsewhere['projectId'], 'p2');
  });

  test('todos_list narrows by project, and to the unfiled ones', () async {
    await callTool('todo_add', {'body': 'in p1', 'projectId': 'p1'});
    await callTool('todo_add', {'body': 'in p2', 'projectId': 'p2'});
    await callTool('todo_add', {'body': 'nowhere'});

    expect(await listTodos(), hasLength(3));
    expect(
      (await listTodos({'projectId': 'p1'})).map((t) => (t! as Map)['body']),
      ['in p1'],
    );
    expect(
      (await listTodos({'projectId': 'none'})).map((t) => (t! as Map)['body']),
      ['nowhere'],
    );
  });

  test('todo_done finishes one without removing it, and reopens it', () async {
    final added =
        (await callTool('todo_add', {'body': 'tick me'})).structured!
            as Map<String, Object?>;

    final finished =
        (await callTool('todo_done', {'id': added['id']})).structured!
            as Map<String, Object?>;
    expect(finished['done'], isTrue);
    expect(finished['doneAt'], isNotNull);

    // Gone from the default list, still in the table — which is the difference
    // between finishing something and deleting it.
    expect(await listTodos(), isEmpty);
    expect(await listTodos({'includeDone': true}), hasLength(1));

    final reopened =
        (await callTool('todo_done', {
              'id': added['id'],
              'done': false,
            })).structured!
            as Map<String, Object?>;
    expect(reopened['done'], isFalse);
    expect(reopened['doneAt'], isNull);
  });

  test('todo_delete removes it, and a ghost id is an error', () async {
    final added =
        (await callTool('todo_add', {'body': 'temporary'})).structured!
            as Map<String, Object?>;

    final deleted =
        (await callTool('todo_delete', {'id': added['id']})).structured!
            as Map<String, Object?>;
    expect(deleted['deleted'], isTrue);
    expect(await listTodos(), isEmpty);

    final ghost = await callTool('todo_delete', {'id': 'ghost'});
    expect(ghost.isError, isTrue);
    expect(ghost.text, contains('ghost'));
  });

  test('a new todo goes to the bottom of the list', () async {
    await callTool('todo_add', {'body': 'first'});
    await callTool('todo_add', {'body': 'second'});
    expect((await listTodos()).map((t) => (t! as Map)['body']), [
      'first',
      'second',
    ]);
  });

  group('notes', () {
    test('note_add files under the session’s project by default', () async {
      final added =
          (await callTool('note_add', {
                'body': 'about the toolbar',
              }, 's1')).structured!
              as Map<String, Object?>;
      expect(added['projectId'], 'p1');
    });

    test('note_add takes "none" and an explicit id', () async {
      final loose =
          (await callTool('note_add', {
                'body': 'belongs to nothing',
                'projectId': 'none',
              }, 's1')).structured!
              as Map<String, Object?>;
      expect(loose['projectId'], isNull);

      final elsewhere =
          (await callTool('note_add', {
                'body': 'belongs elsewhere',
                'projectId': 'p2',
              }, 's1')).structured!
              as Map<String, Object?>;
      expect(elsewhere['projectId'], 'p2');
    });

    test('notes_list narrows by project and by nothing at all', () async {
      await callTool('note_add', {'body': 'in p1', 'projectId': 'p1'});
      await callTool('note_add', {'body': 'nowhere'});

      Future<List<Object?>> notes([
        Map<String, Object?> arguments = const {},
      ]) async =>
          ((await callTool('notes_list', arguments)).structured!
                  as Map<String, Object?>)['notes']!
              as List<Object?>;

      expect(await notes(), hasLength(2));
      expect(
        (await notes({'projectId': 'p1'})).map((n) => (n! as Map)['body']),
        ['in p1'],
      );
      expect(
        (await notes({'projectId': 'none'})).map((n) => (n! as Map)['body']),
        ['nowhere'],
      );
    });
  });
}
