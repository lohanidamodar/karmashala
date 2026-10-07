import 'dart:io';

import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// The New Project dialog's two buttons and its "Create this folder": a
/// missing folder made (and `git init`ed) at the server, refused unless asked,
/// and plain Create recording the root alone where Create & scan finds every
/// repository beneath it.
void main() {
  late RepoToolFixture fixture;

  setUp(() => fixture = RepoToolFixture());
  tearDown(() => fixture.dispose());

  Future<List<String>> checkoutPaths(String projectId) async => [
    for (final r in RepositoryDao(fixture.database).getByProject(projectId))
      r.path.path,
  ];

  group('a missing folder', () {
    test('is made, with its parents, and git init-ed when asked', () async {
      final folder = fixture.path('new/deeper/app');

      final created = await fixture.folders.create(
        name: 'App',
        target: fixture.reach.host!,
        targetPath: folder,
        createFolder: true,
        initGit: true,
        scan: false,
      );

      expect(Directory(folder).existsSync(), isTrue);
      expect(Directory(p.join(folder, '.git')).existsSync(), isTrue);
      expect(created.project.root.path, folder);
      expect(created.repositories.single.path.path, folder);
    });

    test('is made without git when Initialise Git is off', () async {
      final folder = fixture.path('plain');

      await fixture.folders.create(
        name: 'Plain',
        target: fixture.reach.host!,
        targetPath: folder,
        createFolder: true,
      );

      expect(Directory(folder).existsSync(), isTrue);
      expect(Directory(p.join(folder, '.git')).existsSync(), isFalse);
    });

    for (final scan in [true, false]) {
      test('is refused without createFolder (scan: $scan), and nothing is '
          'written', () async {
        final folder = fixture.path('absent');

        await expectLater(
          fixture.folders.create(
            name: 'Absent',
            target: fixture.reach.host!,
            targetPath: folder,
            scan: scan,
          ),
          throwsA(
            isA<RepositoryDiscoveryException>().having(
              (e) => e.message,
              'message',
              contains('does not exist'),
            ),
          ),
        );
        expect(Directory(folder).existsSync(), isFalse);
        expect(ProjectDao(fixture.database).getAll(), isEmpty);
      });
    }

    test('an existing folder is not git init-ed by initGit', () async {
      final folder = fixture.path('existing');
      Directory(folder).createSync(recursive: true);

      await fixture.folders.create(
        name: 'Existing',
        target: fixture.reach.host!,
        targetPath: folder,
        createFolder: true,
        initGit: true,
        scan: false,
      );

      expect(Directory(p.join(folder, '.git')).existsSync(), isFalse);
    });
  });

  group('with repositories nested under the root', () {
    late String root;

    setUp(() {
      root = fixture.path('workspace');
      fixture.repository(p.join(root, 'one'));
      fixture.repository(p.join(root, 'two'));
    });

    test(
      'plain Create records exactly the root and does not recurse',
      () async {
        final created = await fixture.folders.create(
          name: 'Workspace',
          target: fixture.reach.host!,
          targetPath: root,
          scan: false,
        );

        expect(created.repositories, hasLength(1));
        expect(created.repositories.single.path.path, root);
        expect(await checkoutPaths(created.project.id), [root]);
      },
    );

    test('Create & scan still finds every repository beneath it', () async {
      final created = await fixture.folders.create(
        name: 'Workspace',
        target: fixture.reach.host!,
        targetPath: root,
      );

      expect(
        created.repositories.map((r) => r.path.path),
        unorderedEquals([p.join(root, 'one'), p.join(root, 'two')]),
      );
    });
  });
}
