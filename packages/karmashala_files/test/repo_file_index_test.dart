/// Quick Open's index, kept by the server (slice 3c; moved from the app's
/// `repo_file_index_test`): what a walk finds, how long it is trusted, what
/// stales it, its bounds, and what the filesystem does that a walk survives.
library;

import 'dart:async';
import 'dart:io' hide FileStat;

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart' show DirectoryChangeWatcher;
import 'package:karmashala_files/karmashala_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_remote_files.dart';
import 'support/temp_directory.dart';

void main() {
  late Directory root;
  late DateTime clock;
  final here = LocalFileSpace(environmentId: 'windows');

  setUp(() {
    root = Directory.systemTemp.createTempSync('cg_index');
    clock = DateTime.utc(2026, 8, 30, 12);
  });

  tearDown(() => removeTempDirectory(root));

  String at(Directory dir, String relative) =>
      p.joinAll([dir.path, ...relative.split('/')]);

  EnvironmentPath rootAt([String? path]) =>
      EnvironmentPath(environmentId: 'windows', path: path ?? root.path);

  void write(String relative, {Directory? under}) {
    final file = File(at(under ?? root, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('contents of $relative');
  }

  /// An index with no real filesystem watcher, so a test only sees the
  /// staleness it asks for. Watching is exercised separately below.
  RepoFileIndex build({
    int maxFiles = 6000,
    int maxDepth = 10,
    int maxDirectories = 6000,
    Duration refreshInterval = const Duration(seconds: 30),
    DirectoryChangeWatcher? watcher,
    int maxWatchedRoots = 8,
    Map<String, FileSpace>? spaces,
  }) {
    final index = RepoFileIndex(
      spaces: (id) => spaces == null ? here : spaces[id],
      maxFiles: maxFiles,
      maxDepth: maxDepth,
      maxDirectories: maxDirectories,
      refreshInterval: refreshInterval,
      maxWatchedRoots: maxWatchedRoots,
      watcher:
          watcher ?? DirectoryChangeWatcher(recursiveWatchSupported: false),
      now: () => clock,
    );
    addTearDown(index.dispose);
    return index;
  }

  List<String> paths(RepoFiles found) => [...found.files]..sort();

  group('what a walk finds', () {
    test('files under the root, relative and `/`-separated, put back on the '
        'root as its own environment spells it', () async {
      write('lib/main.dart');
      write('README.md');

      final found = await build().index(rootAt());

      expect(paths(found), ['README.md', 'lib/main.dart']);
      expect(found.separator, p.separator);
      final main = found.pathOf(rootAt(), 'lib/main.dart');
      expect(main.path, at(root, 'lib/main.dart'));
      expect(File(main.path).existsSync(), isTrue);
    });

    test('skipped folders are never walked', () async {
      write('lib/main.dart');
      write('node_modules/left-pad/index.js');
      write('build/app.exe');
      write('.git/config');

      expect(paths(await build().index(rootAt())), ['lib/main.dart']);
    });

    test('the depth bound stops the descent', () async {
      write('a/b/c/deep.dart');
      write('shallow.dart');

      expect(paths(await build(maxDepth: 2).index(rootAt())), [
        'shallow.dart',
      ]);
    });

    test('a root that does not exist is empty, not an exception', () async {
      final index = build();
      final missing = rootAt(at(root, 'no-such-repository'));

      expect((await index.index(missing)).files, isEmpty);
      expect(index.isIndexed(missing), isTrue);
    });

    test('an environment the server cannot reach is refused', () async {
      final index = build(spaces: const {});
      await expectLater(
        index.index(rootAt()),
        throwsA(isA<FileSpaceException>()),
      );
    });

    test('an SSH checkout is walked over SFTP, POSIX-separated', () async {
      final files = FakeRemoteFiles()
        ..addDirectory('/home')
        ..addDirectory('/home/me')
        ..addDirectory('/home/me/app');
      // The fake has no listing; a test space lists from its nodes.
      final space = _Listed(files);
      final index = build(spaces: {'ssh:box': space});
      files.addFile('/home/me/app/a.txt', [1]);
      files.addDirectory('/home/me/app/lib');
      files.addFile('/home/me/app/lib/b.dart', [2]);

      const box = EnvironmentPath(environmentId: 'ssh:box', path: '/home/me/app');
      final found = await index.index(box);

      expect(paths(found), ['a.txt', 'lib/b.dart']);
      expect(found.separator, '/');
      expect(found.pathOf(box, 'lib/b.dart').path, '/home/me/app/lib/b.dart');
    });
  });

  group('freshness', () {
    test('a file created after the first index is found once touched', () async {
      write('lib/main.dart');
      final index = build();
      expect(paths(await index.index(rootAt())), ['lib/main.dart']);

      write('lib/new_file.dart');
      expect(
        paths(await index.index(rootAt())),
        ['lib/main.dart'],
        reason: 'fresh: answered from cache',
      );

      index.touch(rootAt());
      expect(paths(await index.index(rootAt())), [
        'lib/main.dart',
        'lib/new_file.dart',
      ]);
    });

    test('a deleted file stops being findable', () async {
      write('lib/main.dart');
      write('lib/gone.dart');
      final index = build();
      expect(paths(await index.index(rootAt())).length, 2);

      File(at(root, 'lib/gone.dart')).deleteSync();
      index.touch(rootAt());

      expect(paths(await index.index(rootAt())), ['lib/main.dart']);
    });

    test('a touch under a checkout, or of a folder above it, stales it',
        () async {
      write('lib/main.dart');
      final index = build();
      await index.index(rootAt());

      index.touchUnder(rootAt(at(root, 'lib/main.dart')));
      expect(index.isFresh(rootAt()), isFalse);

      await index.index(rootAt());
      index.touchUnder(rootAt(root.parent.path));
      expect(index.isFresh(rootAt()), isFalse);
    });

    test('a touch elsewhere leaves it fresh', () async {
      write('lib/main.dart');
      final index = build();
      await index.index(rootAt());

      index.touchUnder(rootAt('${root.path}-sibling'));
      index.touchUnder(
        EnvironmentPath(environmentId: 'wsl:Ubuntu', path: root.path),
      );

      expect(index.isFresh(rootAt()), isTrue);
    });

    test('a touched root keeps its list until it is walked again', () async {
      write('lib/main.dart');
      final index = build();
      await index.index(rootAt());

      index.touch(rootAt());

      expect(index.isFresh(rootAt()), isFalse);
      expect(index.isIndexed(rootAt()), isTrue);
      expect(paths(index.cached(rootAt())), ['lib/main.dart']);
    });

    test('invalidate drops the cached list entirely', () async {
      write('lib/main.dart');
      final index = build();
      await index.index(rootAt());

      index.invalidate(rootAt());

      expect(index.isIndexed(rootAt()), isFalse);
      expect(index.cached(rootAt()).files, isEmpty);
      expect(index.isFresh(rootAt()), isFalse);
    });

    test('the cache goes stale on its own once the interval passes', () async {
      write('lib/main.dart');
      final index = build(refreshInterval: const Duration(seconds: 30));
      await index.index(rootAt());
      expect(index.isFresh(rootAt()), isTrue);

      write('lib/later.dart');
      clock = clock.add(const Duration(seconds: 31));

      expect(index.isFresh(rootAt()), isFalse);
      expect(paths(await index.index(rootAt())), [
        'lib/later.dart',
        'lib/main.dart',
      ]);
    });

    test('a fresh root is answered without touching the filesystem', () async {
      write('lib/main.dart');
      final index = build();
      await index.index(rootAt());

      root.deleteSync(recursive: true);

      expect(paths(await index.index(rootAt())), ['lib/main.dart']);
    });

    test('a change during a walk marks the result it produces stale', () async {
      write('lib/main.dart');
      final index = build();

      final walk = index.index(rootAt());
      index.touch(rootAt());
      await walk;

      expect(index.isIndexed(rootAt()), isTrue);
      expect(
        index.isFresh(rootAt()),
        isFalse,
        reason: 'published, but not trusted: it may have missed the change',
      );
    });

    test('two repositories keep separate indexes', () async {
      final other = Directory.systemTemp.createTempSync('cg_index_other');
      addTearDown(() => removeTempDirectory(other));
      write('lib/first.dart');
      write('lib/second.dart', under: other);
      final index = build();

      expect(paths(await index.index(rootAt())), ['lib/first.dart']);
      expect(paths(await index.index(rootAt(other.path))), [
        'lib/second.dart',
      ]);

      index.touch(rootAt());

      expect(index.isFresh(rootAt()), isFalse);
      expect(index.isFresh(rootAt(other.path)), isTrue);
    });

    test('a walk in flight is shared, not repeated', () async {
      write('a.dart');
      final index = build();
      final first = index.index(rootAt());
      final second = index.index(rootAt());
      expect(identical(first, second), isTrue);
      await first;
    });
  });

  group('the change watcher', () {
    late StreamController<String> changed;

    DirectoryChangeWatcher fake() {
      changed = StreamController<String>.broadcast();
      addTearDown(changed.close);
      return DirectoryChangeWatcher(
        debounce: const Duration(milliseconds: 20),
        maxDebounce: const Duration(milliseconds: 60),
        source: (_) => changed.stream,
        recursiveWatchSupported: true,
      );
    }

    test('a watched change marks the root stale', () async {
      write('lib/main.dart');
      final index = build(watcher: fake());
      await index.index(rootAt());
      expect(index.isFresh(rootAt()), isTrue);

      write('lib/written_by_an_agent.dart');
      changed.add(at(root, 'lib/written_by_an_agent.dart'));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(index.isFresh(rootAt()), isFalse);
      expect(paths(await index.index(rootAt())), [
        'lib/main.dart',
        'lib/written_by_an_agent.dart',
      ]);
    });

    test('a change inside a skipped folder is not worth a re-walk', () async {
      write('lib/main.dart');
      final index = build(watcher: fake());
      await index.index(rootAt());

      changed.add(at(root, 'build/app.exe'));
      changed.add(at(root, '.dart_tool/package_config.json'));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(index.isFresh(rootAt()), isTrue);
    });

    test('a share is never watched, nor an SFTP host: a recursive watch held '
        r'open on \\wsl.localhost is background access antivirus scans',
        () async {
      final watcher = fake();
      final index = build(
        watcher: watcher,
        spaces: {
          'wsl:Ubuntu': wslFileSpace(
            environmentId: 'wsl:Ubuntu',
            distribution: 'Ubuntu',
            label: 'Ubuntu',
          ),
          'ssh:box': SftpFileSpace(files: FakeRemoteFiles(), label: 'box'),
        },
      );

      await index.index(
        const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/app'),
      );
      await index.index(
        const EnvironmentPath(environmentId: 'ssh:box', path: '/home/app'),
      );

      expect(watcher.watched, isEmpty);
    });

    test('watches are capped, oldest root dropped first', () async {
      final watcher = fake();
      final index = build(watcher: watcher, maxWatchedRoots: 2);

      await index.index(rootAt(at(root, 'one')));
      await index.index(rootAt(at(root, 'two')));
      await index.index(rootAt(at(root, 'three')));

      expect(watcher.watched, [at(root, 'two'), at(root, 'three')]);
    });
  });

  group('bounds', () {
    test('a broad tree of empty directories stops at the directory bound',
        () async {
      for (var i = 0; i < 300; i++) {
        Directory(
          at(root, 'd${i.toString().padLeft(3, '0')}'),
        ).createSync(recursive: true);
      }
      write('only.dart');

      final index = build(maxDirectories: 50);
      await index.index(rootAt());

      final stats = index.statsFor(rootAt())!;
      expect(stats.directoriesVisited, 50);
      expect(stats.truncated, isTrue);
    });

    test('the file bound truncates, deterministically, and says so', () async {
      for (var i = 0; i < 30; i++) {
        write('f${i.toString().padLeft(2, '0')}.dart');
      }

      final first = await build(maxFiles: 10).index(rootAt());
      final second = await build(maxFiles: 10).index(rootAt());

      expect(paths(first), [
        for (var i = 0; i < 10; i++) 'f${i.toString().padLeft(2, '0')}.dart',
      ], reason: 'siblings are sorted, so which files survive is not luck');
      expect(paths(second), paths(first));
      expect(first.truncated, isTrue);
    });

    test('an untruncated walk says so', () async {
      write('a.dart');
      final index = build();
      final found = await index.index(rootAt());
      final stats = index.statsFor(rootAt())!;
      expect(found.truncated, isFalse);
      expect(stats.truncated, isFalse);
      expect(stats.cancelled, isFalse);
      expect(stats.files, 1);
      expect(stats.directoriesVisited, 1);
    });

    test('the answer travels whole through its JSON', () async {
      write('lib/a.dart');
      write('lib/b.dart');
      final found = await build(maxFiles: 1).index(rootAt());
      final back = RepoFiles.fromJson(found.toJson());
      expect(back.files, found.files);
      expect(back.separator, found.separator);
      expect(back.truncated, isTrue);
    });
  });

  group('abandoning a walk', () {
    test('an invalidated walk keeps its partial, stale', () async {
      write('at_the_root.dart');
      for (var i = 0; i < 20; i++) {
        write('sub$i/buried.dart');
      }

      final index = build();
      final walk = index.index(rootAt());
      index.invalidate(rootAt());
      await walk;

      final stats = index.statsFor(rootAt())!;
      expect(stats.cancelled, isTrue);
      expect(stats.directoriesVisited, 1);
      expect(paths(index.cached(rootAt())), ['at_the_root.dart']);
      expect(index.isFresh(rootAt()), isFalse);
    });

    test('an index disposed mid-walk does not throw', () async {
      write('a.dart');
      final index = RepoFileIndex(
        spaces: (_) => here,
        watcher: DirectoryChangeWatcher(recursiveWatchSupported: false),
        now: () => clock,
      );
      final walk = index.index(rootAt());
      index.dispose();
      await walk;
      index.dispose();
    });
  });

  group('things the filesystem does that a walk must survive', () {
    Future<bool> linkDirectory(String linkPath, String target) async {
      if (Platform.isWindows) {
        final result = await Process.run('cmd', [
          '/c',
          'mklink',
          '/J',
          linkPath,
          target,
        ]);
        return result.exitCode == 0;
      }
      try {
        Link(linkPath).createSync(target);
        return true;
      } on FileSystemException {
        return false;
      }
    }

    test('a linked directory is not followed', () async {
      write('lib/main.dart');
      // A link pointing at the root itself: following it is an infinite walk.
      if (!await linkDirectory(at(root, 'loop'), root.path)) {
        markTestSkipped('this machine will not create a directory link');
        return;
      }
      addTearDown(() {
        try {
          Link(at(root, 'loop')).deleteSync();
        } on FileSystemException {
          // Gone with the temp directory.
        }
      });

      final index = build();
      expect(paths(await index.index(rootAt())), ['lib/main.dart']);
      expect(
        index.statsFor(rootAt())!.directoriesVisited,
        2,
        reason: 'the root and lib/, and nothing through the link',
      );
    });
  });
}

/// An in-memory SFTP host that can also list, from its own nodes — enough
/// for a walk.
class _Listed extends SftpFileSpace {
  _Listed(this.remote) : super(files: remote, label: 'box');

  final FakeRemoteFiles remote;

  @override
  Future<List<FileEntry>> list(
    EnvironmentPath directory, {
    bool details = true,
  }) async {
    final prefix = directory.path.endsWith('/')
        ? directory.path
        : '${directory.path}/';
    return [
      for (final MapEntry(:key, :value) in remote.nodes.entries)
        if (key.startsWith(prefix) && !key.substring(prefix.length).contains('/'))
          FileEntry(
            name: key.substring(prefix.length),
            path: EnvironmentPath(environmentId: environmentId, path: key),
            kind: value.isDirectory
                ? FileEntryKind.directory
                : FileEntryKind.file,
          ),
    ]..sort(compareFileEntries);
  }
}
