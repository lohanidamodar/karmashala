import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// Finding a project's repositories on this machine's filesystem, and the
/// identity a clone's remote spells. A POSIX environment reached through a
/// runner is `posix_repository_discovery_test.dart`'s.
void main() {
  group('on this machine', () {
    late Directory tmp;
    const service = LocalRepositoryDiscoveryService();

    setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_disc_'));
    tearDown(() => removeTempDirectory(tmp));

    EnvironmentPath rootAt(String path) =>
        EnvironmentPath(environmentId: 'windows', path: path);

    void makeRepoDir(String relative) {
      Directory(p.join(tmp.path, relative, '.git')).createSync(recursive: true);
    }

    test('discovers a repo marked by a .git directory', () async {
      makeRepoDir('app');
      final found = await service.discover(rootAt(tmp.path));
      expect(found.map((r) => r.name), ['app']);
      expect(found.single.path.environmentId, 'windows');
    });

    test('discovers a repo marked by a .git FILE (worktree/submodule)', () async {
      final repo = Directory(p.join(tmp.path, 'wt'))
        ..createSync(recursive: true);
      File(p.join(repo.path, '.git')).writeAsStringSync('gitdir: ../.git/wt');
      final found = await service.discover(rootAt(tmp.path));
      expect(found.map((r) => r.name), ['wt']);
    });

    test('finds sibling and nested repos, including inside a repo', () async {
      makeRepoDir('a');
      makeRepoDir(p.join('group', 'b'));
      makeRepoDir(p.join('a', 'nested'));
      final found = await service.discover(rootAt(tmp.path));
      expect(found.map((r) => r.name).toList(), ['a', 'nested', 'b']);
    });

    test('does not walk into node_modules and friends', () async {
      makeRepoDir(p.join('app', 'node_modules', 'left-pad'));
      makeRepoDir(p.join('app', 'build', 'staged'));
      makeRepoDir('app');
      final found = await service.discover(rootAt(tmp.path));
      expect(found.map((r) => r.name), ['app']);
    });

    test('respects maxDepth', () async {
      makeRepoDir(p.join('one', 'two', 'three', 'deep'));
      expect(await service.discover(rootAt(tmp.path), maxDepth: 2), isEmpty);
      final deep = await service.discover(rootAt(tmp.path), maxDepth: 6);
      expect(deep.map((r) => r.name), ['deep']);
    });

    test('ignores non-repository folders', () async {
      Directory(p.join(tmp.path, 'plain')).createSync(recursive: true);
      expect(await service.discover(rootAt(tmp.path)), isEmpty);
    });

    test('throws a clear error when the root does not exist', () async {
      expect(
        () => service.discover(rootAt(p.join(tmp.path, 'nope'))),
        throwsA(isA<RepositoryDiscoveryException>()),
      );
    });
  });

  group('the identity a remote spells', () {
    // One repository written the different ways one machine ends up holding
    // it: the left is what `.git/config` says, the right the key two of those
    // checkouts have to agree on.
    const cases = <String, String?>{
      'git@github.com:PopupBits/Karmashala.git':
          'github.com/popupbits/karmashala',
      'https://github.com/popupbits/karmashala':
          'github.com/popupbits/karmashala',
      'https://dlohani:ghp_secret@github.com/PopupBits/karmashala.git/':
          'github.com/popupbits/karmashala',
      'ssh://git@github.com:2222/popupbits/karmashala.git':
          'github.com/popupbits/karmashala',
      'git@gitlab.com:acme/platform/api.git': 'gitlab.com/acme/platform/api',
      'https://git.example.com:8443/acme/app.git':
          'git.example.com:8443/acme/app',
      r'C:\src\demo\app': null,
      'file:///home/me/app': null,
      '/home/me/app': null,
      '': null,
    };

    for (final entry in cases.entries) {
      test('${entry.key.isEmpty ? '(empty)' : entry.key} → ${entry.value}', () {
        expect(canonicalRepositoryId(entry.key), entry.value);
      });
    }

    test('nothing read is not a repository with no remote', () {
      expect(canonicalRepositoryId(null), isNull);
    });
  });
}
