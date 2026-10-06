import 'dart:io';

import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// A rescan records every worktree git knows for a recorded checkout, wherever
/// it lives: beside the project, or in a dot-folder the folder walk skips.
void main() {
  late RepoToolFixture fixture;

  setUp(() => fixture = RepoToolFixture());
  tearDown(() => fixture.dispose());

  Set<Checkout> recorded(String projectId) => {
    for (final r in RepositoryDao(fixture.database).getByProject(projectId))
      Checkout(r.path),
  };

  Project projectAt(String root) {
    final created = fixture.project('demo', root, found: [root]);
    return created.project;
  }

  test('a rescan records sibling and dot-folder worktrees', () async {
    final root = fixture.repository(fixture.path('demo'));
    final project = projectAt(root);
    final sibling = fixture.path('.demo-worktrees/feature-a');
    final dotted = p.join(root, '.claude', 'worktrees', 'feature-b');
    fixture.git(root, ['worktree', 'add', '-q', '-b', 'feature-a', sibling]);
    fixture.git(root, ['worktree', 'add', '-q', '-b', 'feature-b', dotted]);

    final added = await fixture.folders.rediscover(project);

    expect(
      {for (final r in added) Checkout(r.path)},
      {Checkout(fixture.here(sibling)), Checkout(fixture.here(dotted))},
    );
    final names = {for (final r in added) r.name};
    expect(names, {'feature-a', 'feature-b'});
    expect(
      [for (final r in added) r.path.path],
      everyElement(isNot(contains('/'))),
      reason: 'a Windows path is recorded with its own separators',
      skip: !Platform.isWindows,
    );
  });

  test('a prunable worktree is not recorded', () async {
    final root = fixture.repository(fixture.path('demo'));
    final project = projectAt(root);
    final gone = fixture.path('.demo-worktrees/gone');
    fixture.git(root, ['worktree', 'add', '-q', '-b', 'gone', gone]);
    Directory(gone).deleteSync(recursive: true);

    final added = await fixture.folders.rediscover(project);

    expect(added, isEmpty);
    expect(recorded(project.id), {Checkout(fixture.here(root))});
  });

  test('a second rescan adds nothing it already recorded', () async {
    final root = fixture.repository(fixture.path('demo'));
    final project = projectAt(root);
    fixture.git(root, [
      'worktree',
      'add',
      '-q',
      '-b',
      'again',
      fixture.path('.demo-worktrees/again'),
    ]);

    await fixture.folders.rediscover(project);
    final second = await fixture.folders.rediscover(project);

    expect(second, isEmpty);
    expect(recorded(project.id), hasLength(2));
  });

  test('a recorded sibling worktree that has gone is retired', () async {
    final root = fixture.repository(fixture.path('demo'));
    final project = projectAt(root);
    final sibling = fixture.path('.demo-worktrees/old');
    fixture.git(root, ['worktree', 'add', '-q', '-b', 'old', sibling]);
    await fixture.folders.rediscover(project);
    expect(recorded(project.id), contains(Checkout(fixture.here(sibling))));

    fixture.git(root, ['worktree', 'remove', sibling]);
    await fixture.folders.rediscover(project);
    // Retiring is not awaited by the rescan: give it its turn.
    for (var i = 0; i < 50; i++) {
      if (!recorded(project.id).contains(Checkout(fixture.here(sibling)))) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(recorded(project.id), {Checkout(fixture.here(root))});
  });

  test('a project created over a clone records its worktrees', () async {
    final root = fixture.repository(fixture.path('demo'));
    final sibling = fixture.path('.demo-worktrees/made-before');
    fixture.git(root, ['worktree', 'add', '-q', '-b', 'made-before', sibling]);

    final created = await fixture.folders.create(
      name: 'demo',
      target: fixture.reach.host!,
      targetPath: root,
    );

    expect(
      {for (final r in created.repositories) Checkout(r.path)},
      {Checkout(fixture.here(root)), Checkout(fixture.here(sibling))},
    );
  });
}
