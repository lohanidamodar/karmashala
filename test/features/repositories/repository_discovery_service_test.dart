import 'dart:io';

import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/repositories/data/repository_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  const service = LocalRepositoryDiscoveryService();

  setUp(() => tmp = Directory.systemTemp.createTempSync('chitra_disc_'));
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

  test(
    'finds multiple sibling and nested repos but does not descend into one',
    () async {
      makeRepoDir('a');
      makeRepoDir(p.join('group', 'b'));
      // A directory *inside* a repo must not be reported even if it looks like one.
      makeRepoDir(p.join('a', 'vendored'));
      final found = await service.discover(rootAt(tmp.path));
      expect(found.map((r) => r.name), ['a', 'b']);
    },
  );

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
