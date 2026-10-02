import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/mcp/tools/project_tool_set.dart';
import 'package:karmashala_projects/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// `project_add` and `project_update`, run by the server over real folders.
///
/// The rule worth pinning is the one a session depends on: **moving a root
/// keeps every checkout's id**, because that id is what a session, a worktree
/// and a pinned default all reference.
void main() {
  late RepoToolFixture fixture;
  late ProjectToolSet tools;
  late ProjectDao projects;
  late RepositoryDao repositories;

  setUp(() {
    fixture = RepoToolFixture();
    tools = ProjectToolSet(
      fixture.context,
      reach: fixture.reach,
      folders: fixture.folders,
    );
    projects = ProjectDao(fixture.database);
    repositories = RepositoryDao(fixture.database);
  });

  tearDown(() => fixture.dispose());

  Future<({Object? value, String? error})> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
  ]) => RepoToolFixture.outcome(tools.call(tool, arguments, null));

  group('project_add', () {
    test('adopts a folder and names it after its own last segment', () async {
      final folder = fixture.path('sample-app');
      fixture.repository(p.join(folder, 'one'));
      fixture.repository(p.join(folder, 'two'));

      final answer = await call('project_add', {'path': folder});
      expect(answer.error, isNull);

      final added = answer.value! as Map<String, Object?>;
      expect(added['name'], 'sample-app');
      expect(added['path'], folder);
      expect(added['environmentId'], localHostEnvironmentId);
      expect(added['projectId'], isA<String>());
      expect(added['count'], 2);

      final stored = projects.getAll().single;
      expect(stored.name, 'sample-app');
      expect(stored.root.path, folder);
      expect(repositories.getByProject(stored.id), hasLength(2));
    });

    test('a folder with no repository in it is its own checkout', () async {
      final folder = fixture.path('plain');
      Directory(folder).createSync();

      final added =
          (await call('project_add', {'path': folder})).value!
              as Map<String, Object?>;
      final checkouts = (added['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(checkouts.single['path'], folder);
    });

    test('a name the caller chose wins over the folder\'s', () async {
      final folder = fixture.path('sample-app');
      Directory(folder).createSync();
      await call('project_add', {'path': folder, 'name': 'Chosen'});
      expect(projects.getAll().single.name, 'Chosen');
    });

    test('clones a repository into the folder named', () async {
      final source = fixture.repository(fixture.path('source'));
      final target = fixture.path('clones/copy');

      final answer = await call('project_add', {
        'path': target,
        'gitUrl': source,
      });

      expect(answer.error, isNull);
      expect(Directory(p.join(target, '.git')).existsSync(), isTrue);
      expect((answer.value! as Map)['name'], 'copy');
      expect(repositories.getAll().single.path.path, target);
    });

    test('a gitUrl with no path lands in ~/karmashala/<repo>', () async {
      final source = fixture.repository(fixture.path('source'));

      final answer = await call('project_add', {'gitUrl': source});

      expect(answer.error, isNull);
      final expected = p.join(fixture.home, 'karmashala', 'source');
      expect((answer.value! as Map)['path'], expected);
      expect(Directory(p.join(expected, '.git')).existsSync(), isTrue);
      expect(projects.getAll().single.name, 'source');
    });

    test(
      'with neither a path nor a gitUrl it refuses and writes nothing',
      () async {
        final answer = await call('project_add');
        expect(answer.error, contains('path'));
        expect(projects.getAll(), isEmpty);
      },
    );

    test('an unknown environment is refused by name', () async {
      final folder = fixture.path('x');
      Directory(folder).createSync();
      final answer = await call('project_add', {
        'path': folder,
        'environmentId': 'nowhere',
      });
      expect(answer.error, contains('nowhere'));
      expect(projects.getAll(), isEmpty);
    });

    test('a folder that is not there changes nothing', () async {
      final answer = await call('project_add', {
        'path': fixture.path('never-created'),
      });
      expect(answer.error, contains('does not exist'));
      expect(projects.getAll(), isEmpty);
    });

    test('a folder on an SSH host is scanned on the box and added', () async {
      _sshEnvironment(fixture);
      final app = fixture.repository(fixture.path('box/app'));
      final answer = await call('project_add', {
        'path': fixture.path('box'),
        'environmentId': 'box',
      });
      expect(answer.error, isNull);
      final checkouts = ((answer.value! as Map)['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(checkouts.single['path'], app);
      expect(checkouts.single['environmentId'], 'box');
    }, testOn: 'posix');
  });

  group('project_update', () {
    late String projectId;
    late String checkoutId;
    late String app;

    setUp(() {
      app = fixture.repository(fixture.path('work/app'));
      final created = fixture.project(
        'Demo',
        fixture.path('work'),
        found: [app],
      );
      projectId = created.project.id;
      checkoutId = created.repositories.single.id;
    });

    test('renames without touching the root', () async {
      final answer = await call('project_update', {
        'projectId': projectId,
        'name': 'Renamed',
      });
      expect(answer.error, isNull);

      final stored = projects.getById(projectId)!;
      expect(stored.name, 'Renamed');
      expect(stored.root.path, fixture.path('work'));
    });

    test('sets the default checkout, and null puts it back', () async {
      await call('project_update', {
        'projectId': projectId,
        'defaultRepositoryId': checkoutId,
      });
      expect(projects.getById(projectId)!.defaultRepositoryId, checkoutId);

      await call('project_update', {
        'projectId': projectId,
        'defaultRepositoryId': null,
      });
      expect(projects.getById(projectId)!.defaultRepositoryId, isNull);
    });

    test('omitting the default leaves the one already chosen', () async {
      await call('project_update', {
        'projectId': projectId,
        'defaultRepositoryId': checkoutId,
      });
      await call('project_update', {'projectId': projectId, 'name': 'Again'});
      expect(projects.getById(projectId)!.defaultRepositoryId, checkoutId);
    });

    test('a move rebases the checkouts and keeps their ids', () async {
      final moved = fixture.path('moved');
      Directory(fixture.path('work')).renameSync(moved);

      final answer = await call('project_update', {
        'projectId': projectId,
        'path': moved,
      });
      expect(answer.error, isNull);

      final result = answer.value! as Map<String, Object?>;
      final rebased = (result['rebased']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(rebased.single['repositoryId'], checkoutId);
      expect(
        repositories.getById(checkoutId)!.path.path,
        p.join(moved, 'app'),
        reason: 'the row every session references is still the same row',
      );
    });

    test('a move to a folder that is not there changes nothing', () async {
      final answer = await call('project_update', {
        'projectId': projectId,
        'path': fixture.path('nowhere'),
      });
      expect(answer.error, contains('does not exist'));
      expect(projects.getById(projectId)!.root.path, fixture.path('work'));
    });

    test('a projectId that names nothing is refused', () async {
      final answer = await call('project_update', {
        'projectId': 'ghost',
        'name': 'x',
      });
      expect(answer.error, contains('no longer in the workspace'));
    });

    test('a missing projectId says where the ids come from', () async {
      final answer = await call('project_update', {'name': 'x'});
      expect(answer.error, contains('list_projects'));
    });

    test('a project moving to an SSH folder that is not there changes '
        'nothing', () async {
      _sshEnvironment(fixture);
      final answer = await call('project_update', {
        'projectId': projectId,
        'environmentId': 'box',
        'path': fixture.path('box/never-created'),
      });
      expect(answer.error, contains('does not exist'));
    }, testOn: 'posix');
  });
}

void _sshEnvironment(RepoToolFixture fixture) => fixture.database.execute(
  'INSERT INTO execution_environments (id, kind, name, created_at) '
  "VALUES ('box', 'ssh', 'Build box', ?);",
  [RepoToolFixture.now.toIso8601String()],
);
