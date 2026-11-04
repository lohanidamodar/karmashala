import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_host/src/mcp/tools/project_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/session_liveness.dart';
import 'package:karmashala_host/src/mcp/tools/workspace_tool_set.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// One folder is one project.
///
/// What happened on 2026-11-04: the Bot added `momo-pasal` and started a
/// Claude Code session in it. Fifty minutes later that session wanted to
/// `flutter_run`, which takes a checkout id; it did not know its own, and
/// `list_checkouts` would not answer without a projectId — so it called
/// `project_add` on its own folder, which made a second project, and every
/// session it started after that was filed under the copy.
void main() {
  late RepoToolFixture fixture;
  late ProjectToolSet projectTools;
  late WorkspaceToolSet workspaceTools;
  late ProjectDao projects;
  late RepositoryDao repositories;
  late String folder;

  setUp(() {
    fixture = RepoToolFixture();
    projectTools = ProjectToolSet(
      fixture.context,
      reach: fixture.reach,
      folders: fixture.folders,
    );
    workspaceTools = WorkspaceToolSet(
      fixture.context,
      reach: fixture.reach,
      folders: fixture.folders,
      worktreesOf: fixture.worktrees.list,
      liveness: SessionLiveness((_) => false),
    );
    projects = ProjectDao(fixture.database);
    repositories = RepositoryDao(fixture.database);
    folder = fixture.repository(fixture.path('games/momo-pasal'));
  });

  tearDown(() => fixture.dispose());

  Future<({Object? value, String? error})> call(
    String tool,
    Map<String, dynamic> arguments, {
    String? caller,
  }) {
    final set = tool == 'list_checkouts' ? workspaceTools : projectTools;
    return RepoToolFixture.outcome(set.call(tool, arguments, caller));
  }

  /// [path] spelled the other way a caller might: the other separators and,
  /// on Windows, where case does not matter, the other case.
  String respelled(String path) {
    final slashed = Platform.isWindows
        ? path.replaceAll(r'\', '/').toUpperCase()
        : path;
    return '$slashed/';
  }

  test('the original sequence makes one project, not two', () async {
    // The Bot adds the folder and starts a session in it.
    final added =
        (await call('project_add', {
              'path': folder,
              'name': 'momo-pasal',
            })).value!
            as Map<String, Object?>;
    final projectId = added['projectId']! as String;
    final checkoutId = repositories.getByProject(projectId).single.id;
    fixture.session('momo', checkoutId);

    // The session asks for its own checkout without knowing its project.
    final listed = await call('list_checkouts', const {}, caller: 'momo');
    expect(listed.error, isNull);
    final own = listed.value! as Map<String, Object?>;
    expect(own['projectId'], projectId);
    final rows = (own['checkouts']! as List).cast<Map<String, Object?>>();
    expect(rows.single['repositoryId'], checkoutId);
    expect(rows.single['yours'], isTrue);

    // And if it adds its folder anyway, however spelled, it is told the
    // project that is already there.
    final again = await call('project_add', {
      'path': respelled(folder),
      'name': 'momo-pasal',
    }, caller: 'momo');
    expect(again.error, isNull);
    final answer = again.value! as Map<String, Object?>;
    expect(answer['projectId'], projectId);
    expect(answer['alreadyInWorkspace'], isTrue);
    expect(
      (answer['checkouts']! as List).cast<Map<String, Object?>>().single,
      containsPair('repositoryId', checkoutId),
    );
    expect(projects.getAll().where((p) => p.kind == null), hasLength(1));
  });

  test('a client writing projects.create at a taken folder is refused', () {
    fixture.project('momo-pasal', folder, found: [folder]);
    expect(
      () => fixture.project('again', respelled(folder)),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.conflict)
            .having((r) => r.message, 'message', contains('momo-pasal')),
      ),
    );
    expect(projects.getAll(), hasLength(1));
  });

  test('list_checkouts from no session still asks for a projectId', () async {
    final answer = await call('list_checkouts', const {});
    expect(answer.error, contains('projectId is required'));
  });

  group('project_merge', () {
    /// The duplicate as the store already holds it, written past the guard
    /// the way the old project_add wrote it.
    ({String keepId, String keepCheckout, String dupId, String dupCheckout})
    duplicated() {
      final keep = fixture.project('momo-pasal', folder, found: [folder]);
      final later = RepoToolFixture.now.add(const Duration(minutes: 50));
      const dupId = 'dup-project';
      const dupCheckout = 'dup-checkout';
      projects.insert(
        Project(
          id: dupId,
          name: 'momo-pasal',
          root: fixture.here(folder),
          createdAt: later,
        ),
      );
      repositories.insert(
        Repository(
          id: dupCheckout,
          projectId: dupId,
          name: 'momo-pasal',
          path: fixture.here(folder),
          createdAt: later,
        ),
      );
      return (
        keepId: keep.project.id,
        keepCheckout: keep.repositories.single.id,
        dupId: dupId,
        dupCheckout: dupCheckout,
      );
    }

    test('moves the sessions to the kept project and removes only the '
        'duplicate entry', () async {
      final ids = duplicated();
      fixture.session('kept-session', ids.keepCheckout);
      fixture.session('art-food', ids.dupCheckout, title: 'art: food');
      fixture.session('art-kitchen', ids.dupCheckout, title: 'art: kitchen');

      final merged = await call('project_merge', {
        'projectId': ids.dupId,
        'into': ids.keepId,
      });
      expect(merged.error, isNull);
      final answer = merged.value! as Map<String, Object?>;
      expect(answer['projectId'], ids.keepId);
      expect(answer['removedProjectId'], ids.dupId);
      expect(answer['sessionsMoved'], 2);

      expect(projects.getById(ids.dupId), isNull);
      expect(repositories.getById(ids.dupCheckout), isNull);
      final sessions = SessionDao(fixture.database);
      for (final id in ['kept-session', 'art-food', 'art-kitchen']) {
        expect(
          sessions.getById(id)?.repositoryId,
          ids.keepCheckout,
          reason: id,
        );
      }
      // The folder is the user's: a merge never touches it.
      expect(Directory(p.join(folder, '.git')).existsSync(), isTrue);
    });

    test(
      'a checkout only the duplicate had moves across with its id',
      () async {
        final ids = duplicated();
        final extra = fixture.repository(p.join(folder, 'tools'));
        repositories.insert(
          Repository(
            id: 'dup-extra',
            projectId: ids.dupId,
            name: 'tools',
            path: fixture.here(extra),
            createdAt: RepoToolFixture.now,
          ),
        );
        fixture.session('tooling', 'dup-extra');

        final merged = await call('project_merge', {
          'projectId': ids.dupId,
          'into': ids.keepId,
        });
        expect(merged.error, isNull);
        expect(repositories.getById('dup-extra')?.projectId, ids.keepId);
        expect(
          SessionDao(fixture.database).getById('tooling')?.repositoryId,
          'dup-extra',
        );
      },
    );

    test('two different folders are refused, and nothing moves', () async {
      final keep = fixture.project('momo-pasal', folder, found: [folder]);
      final otherFolder = fixture.repository(fixture.path('games/kheti'));
      final other = fixture.project('kheti', otherFolder, found: [otherFolder]);

      final merged = await call('project_merge', {
        'projectId': other.project.id,
        'into': keep.project.id,
      });
      expect(merged.error, contains('different folders'));
      expect(projects.getById(other.project.id), isNotNull);
    });
  });
}
