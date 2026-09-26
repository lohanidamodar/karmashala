import 'dart:async';
import 'dart:io';

import 'package:karmashala/src/app/shell/quick_open/repo_file_index.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late DateTime clock;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cg_index');
    clock = DateTime.utc(2026, 8, 30, 12);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(Directory dir, String relative) =>
      '${dir.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';

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
  }) {
    final index = RepoFileIndex(
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

  List<String> paths(List<IndexedFile> files) =>
      files.map((f) => f.relativePath).toList()..sort();

  group('what a walk finds', () {
    test('files under the root, relative and with a host path', () async {
      write('lib/main.dart');
      write('README.md');

      final index = build();
      final files = await index.index(root.path);

      expect(paths(files), ['README.md', 'lib/main.dart']);
      final main = files.firstWhere((f) => f.name == 'main.dart');
      expect(main.hostPath, at(root, 'lib/main.dart'));
      expect(File(main.hostPath).existsSync(), isTrue);
    });

    test('skipped folders are never walked', () async {
      write('lib/main.dart');
      write('node_modules/left-pad/index.js');
      write('build/app.exe');
      write('.git/config');

      final index = build();
      expect(paths(await index.index(root.path)), ['lib/main.dart']);
    });

    test('the depth bound stops the descent', () async {
      write('a/b/c/deep.dart');
      write('shallow.dart');

      final index = build(maxDepth: 2);
      expect(paths(await index.index(root.path)), ['shallow.dart']);
    });

    test('a root that does not exist is empty, not an exception', () async {
      final index = build();
      final missing = at(root, 'no-such-repository');

      expect(await index.index(missing), isEmpty);
      expect(index.isIndexed(missing), isTrue);
    });
  });

  group('freshness', () {
    test(
      'a file created after the first index is found once refreshed',
      () async {
        write('lib/main.dart');
        final index = build();
        expect(paths(await index.index(root.path)), ['lib/main.dart']);

        write('lib/added_later.dart');
        // Still inside the refresh interval and nothing signalled a change, so
        // the cached answer stands — this is the behaviour that made the bug.
        expect(paths(await index.index(root.path)), ['lib/main.dart']);

        index.touch(root.path);
        expect(paths(await index.index(root.path)), [
          'lib/added_later.dart',
          'lib/main.dart',
        ]);
      },
    );

    test('a deleted file stops being findable', () async {
      write('lib/main.dart');
      write('lib/doomed.dart');
      final index = build();
      expect(paths(await index.index(root.path)).length, 2);

      File(at(root, 'lib/doomed.dart')).deleteSync();
      index.touch(root.path);

      expect(paths(await index.index(root.path)), ['lib/main.dart']);
    });

    test('a renamed file is findable under its new name only', () async {
      write('lib/old_name.dart');
      final index = build();
      expect(paths(await index.index(root.path)), ['lib/old_name.dart']);

      File(
        at(root, 'lib/old_name.dart'),
      ).renameSync(at(root, 'lib/new_name.dart'));
      index.touch(root.path);

      expect(paths(await index.index(root.path)), ['lib/new_name.dart']);
    });

    test(
      'touch keeps the cached list, so the first frame stays instant',
      () async {
        write('lib/main.dart');
        final index = build();
        await index.index(root.path);

        index.touch(root.path);

        expect(index.isFresh(root.path), isFalse);
        expect(index.isIndexed(root.path), isTrue);
        expect(paths(index.cached(root.path)), ['lib/main.dart']);
      },
    );

    test('invalidate drops the cached list entirely', () async {
      write('lib/main.dart');
      final index = build();
      await index.index(root.path);

      index.invalidate(root.path);

      expect(index.isIndexed(root.path), isFalse);
      expect(index.cached(root.path), isEmpty);
      expect(index.isFresh(root.path), isFalse);
    });

    test('the cache goes stale on its own once the interval passes', () async {
      write('lib/main.dart');
      final index = build(refreshInterval: const Duration(seconds: 30));
      await index.index(root.path);
      expect(index.isFresh(root.path), isTrue);

      write('lib/added_later.dart');
      clock = clock.add(const Duration(seconds: 31));

      expect(index.isFresh(root.path), isFalse);
      expect(paths(await index.index(root.path)), [
        'lib/added_later.dart',
        'lib/main.dart',
      ]);
    });

    test('a fresh root is answered without touching the filesystem', () async {
      write('lib/main.dart');
      final index = build();
      await index.index(root.path);

      // The whole tree goes away. A fresh index must not notice, must not
      // throw, and must not have walked.
      root.deleteSync(recursive: true);

      expect(paths(await index.index(root.path)), ['lib/main.dart']);
    });

    test('changes reports a walk landing and a root going stale', () async {
      write('lib/main.dart');
      final index = build();
      final seen = <String>[];
      final subscription = index.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await index.index(root.path);
      await pumpEventQueue();
      expect(seen, [root.path], reason: 'the walk landed');

      index.touch(root.path);
      await pumpEventQueue();
      expect(seen, [root.path, root.path], reason: 'and then went stale');

      // Already stale: a second touch is not news.
      index.touch(root.path);
      await pumpEventQueue();
      expect(seen.length, 2);
    });

    test('a change during a walk marks the result it produces stale', () async {
      write('lib/main.dart');
      final index = build();

      final walk = index.index(root.path);
      index.touch(root.path);
      await walk;

      expect(index.isIndexed(root.path), isTrue);
      expect(
        index.isFresh(root.path),
        isFalse,
        reason: 'the tree moved while we were reading it',
      );
    });

    test('two repositories keep separate indexes', () async {
      final other = Directory.systemTemp.createTempSync('cg_index_other');
      addTearDown(() {
        try {
          other.deleteSync(recursive: true);
        } catch (_) {}
      });
      write('lib/first.dart');
      File(at(other, 'lib/second.dart'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');

      final index = build();
      expect(paths(await index.index(root.path)), ['lib/first.dart']);
      expect(paths(await index.index(other.path)), ['lib/second.dart']);

      index.touch(root.path);

      expect(index.isFresh(root.path), isFalse);
      expect(index.isFresh(other.path), isTrue, reason: 'unrelated repository');
      expect(paths(index.cached(other.path)), ['lib/second.dart']);
    });

    test('touchAll stales every known root', () async {
      final other = Directory.systemTemp.createTempSync('cg_index_other');
      addTearDown(() {
        try {
          other.deleteSync(recursive: true);
        } catch (_) {}
      });
      write('a.dart');
      final index = build();
      await index.index(root.path);
      await index.index(other.path);

      index.touchAll();

      expect(index.isFresh(root.path), isFalse);
      expect(index.isFresh(other.path), isFalse);
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
      await index.index(root.path);
      expect(index.isFresh(root.path), isTrue);

      write('lib/written_by_an_agent.dart');
      changed.add(at(root, 'lib/written_by_an_agent.dart'));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(index.isFresh(root.path), isFalse);
      expect(paths(await index.index(root.path)), [
        'lib/main.dart',
        'lib/written_by_an_agent.dart',
      ]);
    });

    test('a change inside a skipped folder is not worth a re-walk', () async {
      write('lib/main.dart');
      final index = build(watcher: fake());
      await index.index(root.path);

      changed.add(at(root, 'build/app.exe'));
      changed.add(at(root, '.dart_tool/package_config.json'));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(index.isFresh(root.path), isTrue);
    });

    test('a share is never watched: a recursive watch held open on '
        r'\\wsl.localhost is background access antivirus scans', () async {
      final watcher = fake();
      final index = build(watcher: watcher);

      await index.index(r'\\wsl.localhost\Ubuntu\home\me\app');
      await index.index(r'\\wsl$\Ubuntu\home\me\app');
      await index.index('//wsl.localhost/Ubuntu/home/me/app');

      expect(watcher.watched, isEmpty);
    });

    test('watches are capped, oldest root dropped first', () async {
      final watcher = fake();
      final index = build(watcher: watcher, maxWatchedRoots: 2);

      await index.index(at(root, 'one'));
      await index.index(at(root, 'two'));
      await index.index(at(root, 'three'));

      expect(watcher.watched, [at(root, 'two'), at(root, 'three')]);
    });
  });

  // Everything above builds the index by hand. This group reads the real
  // provider, because the wiring *is* the fix for the audit's "nothing calls
  // invalidate" — an index that is never told is an index that goes stale.
  group('the provider that the app actually uses', () {
    late ProviderContainer container;
    late RepoFileIndex index;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
      index = container.read(repoFileIndexProvider);
    });

    test('a session revision stales every indexed root', () async {
      write('a.dart');
      await index.index(root.path);
      expect(index.isFresh(root.path), isTrue);

      container.read(sessionsRevisionProvider.notifier).bump();

      expect(index.isFresh(root.path), isFalse);
      expect(paths(index.cached(root.path)), [
        'a.dart',
      ], reason: 'stale, but still drawable on the next first frame');
    });

    test('a checkpoint revision stales every indexed root', () async {
      write('a.dart');
      await index.index(root.path);
      expect(index.isFresh(root.path), isTrue);

      // What the checkpoint recorder bumps when an agent turn ends having
      // actually changed the tree.
      container.read(checkpointsRevisionProvider.notifier).bump();

      expect(index.isFresh(root.path), isFalse);
    });

    test('it watches where the platform can, and says which', () async {
      write('a.dart');
      await index.index(root.path);
      expect(
        index.watchMode,
        Platform.isWindows || Platform.isMacOS
            ? DirectoryWatchMode.recursive
            : DirectoryWatchMode.unsupported,
      );
    });

    test('disposing the container disposes the index', () async {
      write('a.dart');
      await index.index(root.path);
      container.dispose();
      // A disposed index answers from cache and never starts another walk.
      expect(await index.index(root.path), isNotEmpty);
    });
  });

  group('bounds and complexity', () {
    test(
      'a broad tree of empty directories stops at the directory bound',
      () async {
        // The shape the file bound never catches: nothing to count, so the old
        // walk ground through the lot.
        for (var i = 0; i < 300; i++) {
          Directory(
            at(root, 'd${i.toString().padLeft(3, '0')}'),
          ).createSync(recursive: true);
        }
        write('only.dart');

        final index = build(maxDirectories: 50);
        await index.index(root.path);

        final stats = index.statsFor(root.path)!;
        expect(stats.directoriesVisited, 50);
        expect(stats.truncated, isTrue);
      },
    );

    test('the file bound truncates, deterministically', () async {
      for (var i = 0; i < 30; i++) {
        write('f${i.toString().padLeft(2, '0')}.dart');
      }

      final first = paths(await build(maxFiles: 10).index(root.path));
      final second = paths(await build(maxFiles: 10).index(root.path));

      expect(first.length, 10);
      expect(first, [
        'f00.dart',
        'f01.dart',
        'f02.dart',
        'f03.dart',
        'f04.dart',
        'f05.dart',
        'f06.dart',
        'f07.dart',
        'f08.dart',
        'f09.dart',
      ], reason: 'siblings are sorted, so which files survive is not luck');
      expect(second, first, reason: 'and it is the same set every time');
    });

    test('truncation is reported', () async {
      for (var i = 0; i < 30; i++) {
        write('f$i.dart');
      }
      final index = build(maxFiles: 10);
      await index.index(root.path);
      expect(index.statsFor(root.path)!.truncated, isTrue);
    });

    test('an untruncated walk says so', () async {
      write('a.dart');
      final index = build();
      await index.index(root.path);
      final stats = index.statsFor(root.path)!;
      expect(stats.truncated, isFalse);
      expect(stats.cancelled, isFalse);
      expect(stats.files, 1);
      expect(stats.directoriesVisited, 1);
    });
  });

  group('cancellation', () {
    test('cancelling abandons the walk and keeps the partial', () async {
      write('at_the_root.dart');
      for (var i = 0; i < 20; i++) {
        write('sub$i/buried.dart');
      }

      final index = build();
      final walk = index.index(root.path);
      // The walk is parked on its first `list()`. Cancelling now means it stops
      // after the root, before descending into any of the twenty children.
      index.cancel(root.path);
      await walk;

      final stats = index.statsFor(root.path)!;
      expect(stats.cancelled, isTrue);
      expect(stats.directoriesVisited, 1);
      expect(paths(index.cached(root.path)), ['at_the_root.dart']);
      expect(
        index.isFresh(root.path),
        isFalse,
        reason: 'a partial index must be re-walked, not trusted',
      );
    });

    test('a cancelled walk never overwrites a complete one', () async {
      write('a.dart');
      write('nested/b.dart');
      final index = build();
      expect(paths(await index.index(root.path)), ['a.dart', 'nested/b.dart']);

      index.touch(root.path);
      final second = index.index(root.path);
      index.cancel(root.path);
      await second;

      expect(paths(index.cached(root.path)), [
        'a.dart',
        'nested/b.dart',
      ], reason: 'the good list survived the abandoned walk');
    });

    test('refresh abandons a walk in flight and starts a new one', () async {
      write('a.dart');
      final index = build();
      final first = index.index(root.path);
      write('b.dart');
      final second = index.refresh(root.path);

      await first;
      expect(paths(await second), ['a.dart', 'b.dart']);
      expect(index.isFresh(root.path), isTrue);
    });

    test('an index disposed mid-walk does not throw', () async {
      write('a.dart');
      final index = RepoFileIndex(
        watcher: DirectoryChangeWatcher(recursiveWatchSupported: false),
        now: () => clock,
      );
      final walk = index.index(root.path);
      index.dispose();
      await walk;
      // Disposing twice is also fine.
      index.dispose();
    });
  });

  group('things the filesystem does that a walk must survive', () {
    /// Creates a directory link at [linkPath]. On Windows this is a junction
    /// rather than a symlink: `mklink /J` needs no administrator, where
    /// `CreateSymbolicLink` does, and Dart reports both as `Link` when it is
    /// told not to follow them.
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
        } catch (_) {}
      });

      final index = build();
      final files = await index.index(root.path);

      expect(paths(files), ['lib/main.dart']);
      expect(
        index.statsFor(root.path)!.directoriesVisited,
        2,
        reason: 'the root and lib/, and nothing through the link',
      );
    });

    test('a directory it cannot read is skipped, not fatal', () async {
      write('lib/readable.dart');
      final denied = Directory(at(root, 'denied'))..createSync();
      File(at(denied, 'hidden.dart')).writeAsStringSync('x');

      final user = Platform.environment['USERNAME'] ?? '';
      if (!Platform.isWindows || user.isEmpty) {
        markTestSkipped('no portable way to deny read on this platform');
        return;
      }
      await Process.run('icacls', [denied.path, '/deny', '$user:(OI)(CI)(F)']);
      addTearDown(() async {
        // Always give it back, or the temp directory cannot be deleted.
        await Process.run('icacls', [denied.path, '/remove:d', user]);
      });

      // Whether the OS throws or simply reports nothing, "we cannot see in
      // there" is the condition under test; if we can still see in, there is
      // nothing to test and saying so is better than passing vacuously.
      var blind = false;
      try {
        blind = denied.listSync().isEmpty;
      } catch (_) {
        blind = true;
      }
      if (!blind) {
        markTestSkipped('the deny ACE did not take effect');
        return;
      }

      final index = build();
      final files = await index.index(root.path);

      expect(paths(files), ['lib/readable.dart']);
      expect(
        index.statsFor(root.path)!.directoriesVisited,
        greaterThanOrEqualTo(3),
        reason: 'the unreadable folder was visited, failed, and was skipped',
      );
    });
  });
}
