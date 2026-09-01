import 'dart:io';

import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/repositories/data/repository_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  const service = LocalRepositoryDiscoveryService();

  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_disc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

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
    final repo = Directory(p.join(tmp.path, 'wt'))..createSync(recursive: true);
    File(p.join(repo.path, '.git')).writeAsStringSync('gitdir: ../.git/wt');
    final found = await service.discover(rootAt(tmp.path));
    expect(found.map((r) => r.name), ['wt']);
  });

  test('finds sibling and nested repos, including inside a repo', () async {
    makeRepoDir('a');
    makeRepoDir(p.join('group', 'b'));
    // A repository inside a repository is still a repository. A hub repo whose
    // folder holds a dozen clones used to report exactly one row, leaving every
    // session in a sub-folder with nowhere to hang but the hub's own.
    makeRepoDir(p.join('a', 'nested'));
    final found = await service.discover(rootAt(tmp.path));
    // Sorted by path: `a`, then `a/nested`, then `group/b`.
    expect(found.map((r) => r.name).toList(), ['a', 'nested', 'b']);
  });

  test('does not walk into node_modules and friends', () async {
    // The cost of descending into repositories, paid back: the folders that
    // make a scan unaffordable are the ones nobody wants a row for anyway.
    makeRepoDir(p.join('app', 'node_modules', 'left-pad'));
    makeRepoDir(p.join('app', 'build', 'staged'));
    makeRepoDir('app');
    final found = await service.discover(rootAt(tmp.path));
    expect(found.map((r) => r.name), ['app']);
  });

  test('respects maxDepth', () async {
    makeRepoDir(p.join('one', 'two', 'three', 'deep'));
    final shallow = await service.discover(rootAt(tmp.path), maxDepth: 2);
    expect(shallow, isEmpty);
    final deep = await service.discover(rootAt(tmp.path), maxDepth: 6);
    expect(deep.map((r) => r.name), ['deep']);
  });

  test('ignores non-repository folders', () async {
    Directory(p.join(tmp.path, 'plain')).createSync(recursive: true);
    final found = await service.discover(rootAt(tmp.path));
    expect(found, isEmpty);
  });

  test('throws a clear error when the root does not exist', () async {
    expect(
      () => service.discover(rootAt(p.join(tmp.path, 'nope'))),
      throwsA(isA<RepositoryDiscoveryException>()),
    );
  });
}
