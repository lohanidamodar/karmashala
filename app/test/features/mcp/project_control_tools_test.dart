import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// `project_add` and `project_update` over the endpoint an agent really calls.
///
/// The rule worth pinning is the one a session depends on: **moving a root
/// keeps every checkout's id**, because that id is what a session, a worktree
/// and a pinned default all reference.
void main() {
  late Directory tmp;
  late Directory work;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_project_tools_');
    work = Directory.systemTemp.createTempSync('karmashala_project_work_');
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(
              responder: (_) =>
                  const CommandResult(exitCode: 0, stdout: '', stderr: ''),
            ),
          ),
        ),
        deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
        probeGateProvider.overrideWithValue(headlessProbeGate),
        gitFilesProvider.overrideWithValue(noGitFiles),
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
    for (final directory in [tmp, work]) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  Future<({bool isError, String text, Object? structured})> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final json =
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp/${json['mcpToken']}'),
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

  group('project_add', () {
    test('adopts a folder and names it after its own last segment', () async {
      final folder = Directory(p.join(work.path, 'sample-app'))
        ..createSync(recursive: true);

      final call = await callTool('project_add', {'path': folder.path});
      expect(call.isError, isFalse, reason: call.text);

      final added = call.structured! as Map<String, Object?>;
      expect(added['name'], 'sample-app');
      expect(added['path'], folder.path);
      expect(added['projectId'], isA<String>());

      final stored = ProjectDao(db).getAll().single;
      expect(stored.name, 'sample-app');
      expect(stored.root.path, folder.path);
    });

    test('a name the caller chose wins over the folder\'s', () async {
      final folder = Directory(p.join(work.path, 'sample-app'))
        ..createSync(recursive: true);
      await callTool('project_add', {'path': folder.path, 'name': 'Chosen'});
      expect(ProjectDao(db).getAll().single.name, 'Chosen');
    });

    test(
      'with neither a path nor a gitUrl it refuses and writes nothing',
      () async {
        final call = await callTool('project_add');
        expect(call.isError, isTrue);
        expect(call.text, contains('path'));
        expect(ProjectDao(db).getAll(), isEmpty);
      },
    );

    test('an unknown environment is refused by name', () async {
      final folder = Directory(p.join(work.path, 'x'))..createSync();
      final call = await callTool('project_add', {
        'path': folder.path,
        'environmentId': 'nowhere',
      });
      expect(call.isError, isTrue);
      expect(call.text, contains('nowhere'));
      expect(ProjectDao(db).getAll(), isEmpty);
    });

    test('a folder that is not there changes nothing', () async {
      final call = await callTool('project_add', {
        'path': p.join(work.path, 'never-created'),
      });
      expect(call.isError, isTrue);
      expect(ProjectDao(db).getAll(), isEmpty);
    });
  });

  group('project_update', () {
    setUp(() {
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
    });

    test('renames without touching the root', () async {
      final call = await callTool('project_update', {
        'projectId': 'p1',
        'name': 'Renamed',
      });
      expect(call.isError, isFalse, reason: call.text);

      final stored = ProjectDao(db).getById('p1')!;
      expect(stored.name, 'Renamed');
      expect(stored.root.path, r'C:\src\demo');
    });

    test('sets the default checkout, and null puts it back', () async {
      await callTool('project_update', {
        'projectId': 'p1',
        'defaultRepositoryId': 'r1',
      });
      expect(ProjectDao(db).getById('p1')!.defaultRepositoryId, 'r1');

      await callTool('project_update', {
        'projectId': 'p1',
        'defaultRepositoryId': null,
      });
      expect(ProjectDao(db).getById('p1')!.defaultRepositoryId, isNull);
    });

    test('omitting the default leaves the one already chosen', () async {
      ProjectDao(db).setDefaultRepository('p1', 'r1');
      await callTool('project_update', {'projectId': 'p1', 'name': 'Again'});
      expect(ProjectDao(db).getById('p1')!.defaultRepositoryId, 'r1');
    });

    test('a move rebases the checkouts and keeps their ids', () async {
      final moved = Directory(p.join(work.path, 'moved'))
        ..createSync(recursive: true);
      Directory(p.join(moved.path, 'app')).createSync();

      ProjectDao(db).update(
        ProjectDao(db)
            .getById('p1')!
            .copyWith(
              root: EnvironmentPath(
                environmentId: localHostEnvironmentId,
                path: work.path,
              ),
            ),
      );
      RepositoryDao(db).update(
        RepositoryDao(db)
            .getById('r1')!
            .copyWith(
              path: EnvironmentPath(
                environmentId: localHostEnvironmentId,
                path: p.join(work.path, 'app'),
              ),
            ),
      );

      final call = await callTool('project_update', {
        'projectId': 'p1',
        'path': moved.path,
      });
      expect(call.isError, isFalse, reason: call.text);

      final result = call.structured! as Map<String, Object?>;
      final rebased = (result['rebased']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(rebased.single['repositoryId'], 'r1');
      expect(
        RepositoryDao(db).getById('r1')!.path.path,
        p.join(moved.path, 'app'),
      );
      expect(
        RepositoryDao(db).getById('r1'),
        isNotNull,
        reason: 'the row every session references is still the same row',
      );
    });

    test('a projectId that names nothing is refused', () async {
      final call = await callTool('project_update', {
        'projectId': 'ghost',
        'name': 'x',
      });
      expect(call.isError, isTrue);
      expect(call.text, contains('no longer in the workspace'));
    });

    test('a missing projectId says where the ids come from', () async {
      final call = await callTool('project_update', {'name': 'x'});
      expect(call.isError, isTrue);
      expect(call.text, contains('list_projects'));
    });
  });
}
