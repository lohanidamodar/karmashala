import 'dart:async';
import 'dart:io';

import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

void main() {
  const root = r'C:\repo';
  late StreamController<String> paths;
  late DirectoryChangeWatcher watcher;

  DirectoryChangeWatcher build({
    Duration debounce = const Duration(milliseconds: 60),
    Duration maxDebounce = const Duration(milliseconds: 200),
    bool supported = true,
    Stream<String> Function(String root)? source,
  }) {
    paths = StreamController<String>.broadcast();
    addTearDown(paths.close);
    watcher = DirectoryChangeWatcher(
      debounce: debounce,
      maxDebounce: maxDebounce,
      source: source ?? (_) => paths.stream,
      recursiveWatchSupported: supported,
    );
    addTearDown(watcher.dispose);
    return watcher;
  }

  Future<void> settle([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('debouncing', () {
    test('a burst of changes lands as exactly one callback', () async {
      build();
      var fired = 0;
      expect(watcher.watch(root, () => fired++), isTrue);

      for (var i = 0; i < 40; i++) {
        paths.add('$root\\lib\\file$i.dart');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fired, 0, reason: 'still inside the quiet period');

      await settle();
      expect(fired, 1, reason: 'forty writes, one re-walk');
    });

    test('two separated bursts are two callbacks', () async {
      build();
      var fired = 0;
      watcher.watch(root, () => fired++);

      paths.add('$root\\a.dart');
      await settle();
      paths.add('$root\\b.dart');
      await settle();

      expect(fired, 2);
    });

    test(
      'a stream that never settles still reports within the ceiling',
      () async {
        build(
          debounce: const Duration(milliseconds: 80),
          maxDebounce: const Duration(milliseconds: 150),
        );
        var fired = 0;
        watcher.watch(root, () => fired++);

        // Continuous writes reset the quiet timer, so only the ceiling fires.
        final ticker = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => paths.add('$root\\noisy'),
        );
        addTearDown(ticker.cancel);

        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(fired, greaterThanOrEqualTo(1));
      },
    );
  });

  group('filtering', () {
    test('ignored paths never wake the callback', () async {
      build();
      var fired = 0;
      watcher.watch(
        root,
        () => fired++,
        ignore: (path) => path.contains(r'\build\'),
      );

      paths.add('$root\\build\\app.exe');
      paths.add('$root\\build\\app.pdb');
      await settle();
      expect(fired, 0);

      paths.add('$root\\lib\\main.dart');
      await settle();
      expect(fired, 1);
    });
  });

  group('when a watch cannot be had', () {
    test('an unsupported platform declines rather than throwing', () async {
      build(supported: false);
      var fired = 0;
      expect(watcher.watch(root, () => fired++), isFalse);
      expect(watcher.isWatching(root), isFalse);
      expect(watcher.mode, DirectoryWatchMode.unsupported);

      paths.add('$root\\lib\\main.dart');
      await settle();
      expect(fired, 0, reason: 'nothing was ever subscribed');
    });

    test('a source that throws leaves the watcher usable', () {
      build(source: (_) => throw const FileSystemException('no handle'));
      expect(watcher.watch(root, () {}), isFalse);
      expect(watcher.isWatching(root), isFalse);
    });

    test('a watch that errors drops out so the caller falls back', () async {
      final errors = StreamController<String>.broadcast();
      addTearDown(errors.close);
      final w = DirectoryChangeWatcher(
        debounce: const Duration(milliseconds: 20),
        source: (_) => errors.stream,
        recursiveWatchSupported: true,
      );
      addTearDown(w.dispose);

      expect(w.watch(root, () {}), isTrue);
      errors.addError(const FileSystemException('buffer overflow'));
      await settle(60);
      expect(w.isWatching(root), isFalse);
    });
  });

  group('lifecycle', () {
    test('unwatch stops a pending callback', () async {
      build();
      var fired = 0;
      watcher.watch(root, () => fired++);
      paths.add('$root\\a.dart');
      watcher.unwatch(root);

      await settle();
      expect(fired, 0);
      expect(watcher.isWatching(root), isFalse);
    });

    test('dispose stops a pending callback and refuses new watches', () async {
      build();
      var fired = 0;
      watcher.watch(root, () => fired++);
      paths.add('$root\\a.dart');
      watcher.dispose();

      await settle();
      expect(fired, 0);
      expect(watcher.watch(root, () => fired++), isFalse);
    });

    test('watching the same root twice keeps one subscription', () {
      build();
      expect(watcher.watch(root, () {}), isTrue);
      expect(watcher.watch(root, () {}), isTrue);
      expect(watcher.watched, [root]);
    });
  });

  group(
    'against the real filesystem',
    () {
      // Injected streams cannot show that a real OS watch sees a real file.
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('cg_watch'));
      tearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('a recursive watch sees a file created in a subdirectory', () async {
        final real = DirectoryChangeWatcher(
          debounce: const Duration(milliseconds: 100),
          maxDebounce: const Duration(seconds: 1),
        );
        addTearDown(real.dispose);

        final done = Completer<void>();
        expect(
          real.watch(dir.path, () {
            if (!done.isCompleted) done.complete();
          }),
          isTrue,
        );

        // Give the OS a moment to arm the handle before writing.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        Directory(
          '${dir.path}${Platform.pathSeparator}nested',
        ).createSync(recursive: true);
        File(
          '${dir.path}${Platform.pathSeparator}nested'
          '${Platform.pathSeparator}new.dart',
        ).writeAsStringSync('void main() {}');

        await done.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () =>
              fail('the recursive watch never reported the new file'),
        );
      });
    },
    skip: Platform.isWindows || Platform.isMacOS
        ? false
        : 'no affordable recursive watch on this platform',
  );
}
