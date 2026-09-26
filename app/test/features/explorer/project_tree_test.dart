import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/checkout.dart';
import 'package:karmashala/src/features/explorer/application/project_tree.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// Which row each session's *working directory* puts it on.
///
/// The Explorer no longer draws this tree — it lists sessions, and checkouts
/// moved to the right sidebar — but `placeSessions` survives because
/// `remote_bindings.dart` still groups a project's sessions by checkout for the
/// companion app. What it must get right is unchanged: with several sub-folders
/// each holding a repository, grouping sessions by the row they happen to be
/// *recorded* against puts every one of them in the same pile, and grouping by
/// directory is what answers "what is this agent working on".
void main() {
  EnvironmentPath win(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  Repository repo(String id, String name, String path) =>
      repository(id: id, name: name, path: path);

  GitWorktree worktreeAt(String path, {String? branch, bool bare = false}) =>
      GitWorktree(path: win(path), branch: branch, isBare: bare);

  /// Repositories as peers, with no worktrees folded under any of them —
  /// exactly the shape `remote_bindings.dart` builds, which is now the only
  /// production caller of [placeSessions].
  ProjectTree flatTree(List<Repository> repositories) => ProjectTree(
    repositories: [
      for (final repository in repositories)
        RepoNode(repository: repository, worktreesKnown: false),
    ],
  );

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
      final tree = flatTree([hub, alpha, beta]);
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
      final wtPath = win(r'C:\ws\hub\projects\alpha\wt-x');
      final tree = ProjectTree(
        repositories: [
          RepoNode(
            repository: alpha,
            worktrees: [
              WorktreeNode(
                worktree: worktreeAt(wtPath.path, branch: 'feature/x'),
                owner: alpha,
              ),
            ],
          ),
        ],
      );
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
      final tree = flatTree([hub]);
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
      final tree = flatTree([alpha]);
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
