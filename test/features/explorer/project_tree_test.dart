import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/explorer/application/checkout.dart';
import 'package:chitragupta/src/features/explorer/application/project_tree.dart';
import 'package:chitragupta/src/features/git/domain/git_worktree.dart';
import 'package:chitragupta/src/features/repositories/domain/repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// The tree's two pure halves: which rows are repositories and which are
/// worktrees of another, and which row each session's *working directory* puts
/// it on.
///
/// The second is the one the owner asked for in as many words: with several
/// sub-folders each holding a repository, a tree that groups sessions by the
/// row they happen to be recorded against puts every one of them in the same
/// pile. Grouping by directory is what makes the tree answer "what is this
/// agent working on".
void main() {
  EnvironmentPath win(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  Repository repo(String id, String name, String path) =>
      repository(id: id, name: name, path: path);

  GitWorktree worktreeAt(String path, {String? branch, bool bare = false}) =>
      GitWorktree(path: win(path), branch: branch, isBare: bare);

  group('canonical paths', () {
    test('a Windows path is one place however it is spelled', () {
      // git worktree list reports forward slashes; the database stores
      // backslashes; `Session.worktree` is built with p.windows.join. Three
      // spellings, one working tree — and one `git status`.
      expect(samePath(r'C:\src\demo', 'C:/src/demo'), isTrue);
      expect(samePath(r'C:\src\Demo\', 'c:/src/demo'), isTrue);
      expect(samePath(r'C:\src\demo', r'C:\src\demo2'), isFalse);
    });

    test('a POSIX path is case-sensitive, because the filesystem is', () {
      expect(samePath('/home/me/App', '/home/me/app'), isFalse);
      expect(samePath('/home/me/app/', '/home/me/app'), isTrue);
    });

    test('Checkout keys collapse spellings so a family caches once', () {
      expect(Checkout(win(r'C:\src\demo')), Checkout(win('C:/src/demo')));
      expect(
        Checkout(win(r'C:\src\demo')).hashCode,
        Checkout(win('C:/src/demo')).hashCode,
      );
      // …but never across environments. The same text in two environments is
      // two directories.
      expect(
        Checkout(win(r'C:\src\demo')) ==
            const Checkout(
              EnvironmentPath(environmentId: 'wsl:U', path: r'C:\src\demo'),
            ),
        isFalse,
      );
    });

    test('relativeSubPath is what a row subtitle reads', () {
      expect(
        relativeSubPath(win(r'C:\ws'), win(r'C:\ws\projects\app\app')),
        'projects/app/app',
      );
      expect(relativeSubPath(win(r'C:\ws'), win(r'C:\ws')), isNull);
      expect(relativeSubPath(win(r'C:\ws'), win(r'D:\other')), isNull);
    });
  });

  group('buildProjectTree', () {
    test('a repository that is a worktree of another folds under it', () {
      // The shape of this app's own workspace: a clone plus sibling wt-* folders
      // that discovery calls repositories because a worktree has a .git file.
      final main = repo('r1', 'app', r'C:\ws\app');
      final wt = repo('r2', 'wt-feature', r'C:\ws\wt-feature');
      final list = [
        worktreeAt(r'C:\ws\app', branch: 'main'),
        worktreeAt(r'C:\ws\wt-feature', branch: 'feature/x'),
      ];

      final tree = buildProjectTree([main, wt], [list, list]);

      expect(tree.repositories.map((n) => n.repository.id), ['r1']);
      final worktrees = tree.repositories.single.worktrees;
      expect(worktrees.single.branch, 'feature/x');
      // And it is startable, because the workspace has a row for it.
      expect(worktrees.single.repository?.id, 'r2');
      expect(worktrees.single.startable, isTrue);
    });

    test('a worktree with no workspace row is described but not startable', () {
      final main = repo('r1', 'app', r'C:\ws\app');
      final tree = buildProjectTree(
        [main],
        [
          [
            worktreeAt(r'C:\ws\app', branch: 'main'),
            worktreeAt(r'C:\elsewhere\wt', branch: 'feature/y'),
          ],
        ],
      );
      final child = tree.repositories.single.worktrees.single;
      expect(child.branch, 'feature/y');
      expect(child.startable, isFalse);
    });

    test('git reporting forward slashes still matches the stored row', () {
      final main = repo('r1', 'app', r'C:\ws\app');
      final wt = repo('r2', 'wt', r'C:\ws\wt');
      final list = [worktreeAt('C:/ws/app'), worktreeAt('C:/ws/wt')];
      final tree = buildProjectTree([main, wt], [list, list]);

      expect(tree.repositories.map((n) => n.repository.id), ['r1']);
      // The stored spelling wins, so the stat provider keys on the same entry
      // the cards inside use.
      expect(tree.repositories.single.worktrees.single.path.path, r'C:\ws\wt');
    });

    test('the bare entry is never a row', () {
      final main = repo('r1', 'app', r'C:\ws\app');
      final tree = buildProjectTree(
        [main],
        [
          [
            worktreeAt(r'C:\ws\app'),
            worktreeAt(r'C:\ws\bare', bare: true),
            worktreeAt(r'C:\ws\wt', branch: 'x'),
          ],
        ],
      );
      expect(tree.repositories.single.worktrees.map((w) => w.branch), ['x']);
    });

    test('a repository git could not answer for stays a row, and says so', () {
      // A folder that is not a checkout, a git that is not installed, or a
      // worktree another environment's git wrote (Loop 50 §8.4). "We could not
      // ask" is a different fact from "there are none".
      final tree = buildProjectTree([repo('r1', 'app', r'C:\ws\app')], [null]);
      expect(tree.repositories.single.worktreesKnown, isFalse);
      expect(tree.repositories.single.worktrees, isEmpty);
    });

    test(
      'a worktree whose main checkout is not in the workspace stays a row',
      () {
        // Hiding a folder the user can see is worse than listing it twice.
        final wt = repo('r2', 'wt', r'C:\ws\wt');
        final tree = buildProjectTree(
          [wt],
          [
            [worktreeAt(r'D:\elsewhere\app'), worktreeAt(r'C:\ws\wt')],
          ],
        );
        expect(tree.repositories.map((n) => n.repository.id), ['r2']);
      },
    );
  });

  group('placeSessions', () {
    // A hub project: the hub itself is a repository, and three cloned projects
    // sit inside it. This is the case the owner described.
    final hub = repo('hub', 'popupbits', r'C:\ws\hub');
    final alpha = repo('a', 'alpha', r'C:\ws\hub\projects\alpha\alpha');
    final beta = repo('b', 'beta', r'C:\ws\hub\projects\beta');

    SessionLocation native(String id, Repository at, {EnvironmentPath? wt}) =>
        SessionLocation(
          repositoryId: at.id,
          directory: wt ?? at.path,
          native: session(id: id, repositoryId: at.id, worktree: wt),
        );

    test('each session lands on the deepest row that contains it', () {
      final tree = buildProjectTree(
        [hub, alpha, beta],
        [
          [worktreeAt(r'C:\ws\hub')],
          [worktreeAt(r'C:\ws\hub\projects\alpha\alpha')],
          [worktreeAt(r'C:\ws\hub\projects\beta')],
        ],
      );
      final placement = placeSessions(tree, [
        native('s0', hub),
        native('s1', alpha),
        native('s2', alpha),
        native('s3', beta),
      ]);

      // Not one pile under the hub: three rows, each with its own work.
      expect(placement.at(repoRowKey(hub)).native.map((s) => s.id), ['s0']);
      expect(placement.at(repoRowKey(alpha)).native.map((s) => s.id), [
        's1',
        's2',
      ]);
      expect(placement.at(repoRowKey(beta)).native.map((s) => s.id), ['s3']);
    });

    test('a session in a worktree lands on the worktree row', () {
      final tree = buildProjectTree(
        [alpha],
        [
          [
            worktreeAt(r'C:\ws\hub\projects\alpha\alpha'),
            worktreeAt(r'C:\ws\hub\projects\alpha\wt-x', branch: 'feature/x'),
          ],
        ],
      );
      final wtPath = win(r'C:\ws\hub\projects\alpha\wt-x');
      final placement = placeSessions(tree, [
        native('s1', alpha),
        native('s2', alpha, wt: wtPath),
      ]);

      expect(placement.at(repoRowKey(alpha)).native.map((s) => s.id), ['s1']);
      expect(placement.at(worktreeRowKey(wtPath)).native.map((s) => s.id), [
        's2',
      ]);
    });

    test('a directory no row records gets a "not scanned" row of its own', () {
      // The scanner has not been here since the folder appeared. The session
      // still nests where it belongs rather than being dumped on the hub.
      final tree = buildProjectTree(
        [hub],
        [
          [worktreeAt(r'C:\ws\hub')],
        ],
      );
      final unscanned = SessionLocation(
        repositoryId: hub.id,
        directory: win(r'C:\ws\hub\projects\gamma'),
        native: session(id: 's9', repositoryId: hub.id),
      );

      final placement = placeSessions(tree, [native('s0', hub), unscanned]);

      final folders = placement.under(repoRowKey(hub));
      expect(folders.single.label, 'projects/gamma');
      expect(
        placement.at(folderRowKey(folders.single.path)).native.map((s) => s.id),
        ['s9'],
      );
      // …and the hub keeps only what is actually in the hub.
      expect(placement.at(repoRowKey(hub)).native.map((s) => s.id), ['s0']);
    });

    test('a session nothing contains is still drawn somewhere', () {
      // A WSL cwd against Windows rows: no row contains it, and a path is never
      // compared across environments. It falls back to the row it is recorded
      // against, because a session drawn nowhere is a lost piece of work.
      final tree = buildProjectTree(
        [alpha],
        [
          [worktreeAt(r'C:\ws\hub\projects\alpha\alpha')],
        ],
      );
      final elsewhere = SessionLocation(
        repositoryId: alpha.id,
        directory: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/alpha',
        ),
        native: session(id: 's7', repositoryId: alpha.id),
      );
      final placement = placeSessions(tree, [elsewhere]);
      expect(placement.at(repoRowKey(alpha)).native.map((s) => s.id), ['s7']);
      expect(placement.under(repoRowKey(alpha)), isEmpty);
    });

    test('an empty tree places nothing rather than throwing', () {
      expect(placeSessions(ProjectTree.empty, []).onRow, isEmpty);
    });
  });
}
