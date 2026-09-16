import 'dart:async';
import 'dart:io';

import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/quick_open/repo_file_index.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';

/// The dialog's side of the file index: that it draws what is cached, notices
/// the index refreshing behind it, and lets go of a walk it no longer wants.
///
/// The index's own behaviour — bounds, determinism, staleness — is in
/// `repo_file_index_test.dart`; this is only the wiring.
void main() {
  late AppDatabase db;
  late Directory root;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project(name: 'Karmashala'));
    RepositoryDao(db).insert(repository(name: 'app'));
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', title: 'Fix login redirect'));
    root = Directory.systemTemp.createTempSync('cg_qo_index');
  });

  tearDown(() {
    db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  String at(String relative) =>
      '${root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';

  void write(String relative) {
    final file = File(at(relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('// $relative');
  }

  /// Riverpod's `Override` is a sealed type its public library does not
  /// export, so containers are assembled here rather than passed as lists.
  ProviderContainer containerWith(RepoFileIndex index) => ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      quickOpenFileRootProvider.overrideWithValue(root.path),
      repoFileIndexProvider.overrideWithValue(index),
    ],
  );

  Future<ProviderContainer> open(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  /// Walks the tree once, awaited, before the palette opens.
  ///
  /// **Counted, not timed.** A walk is real filesystem work — `directory.list`
  /// behind a binding whose clock is fake — and the old helper spent eight
  /// 40 ms slices hoping it had landed, which under load it had not. `runAsync`
  /// is where that I/O can actually complete, so the walk is done there and
  /// awaited; the palette then finds a fresh root and answers it from cache.
  /// Nothing after this waits on wall clock for I/O that had not arrived.
  Future<void> walkFirst(WidgetTester tester, RepoFileIndex index) async {
    final files = await tester.runAsync(() => index.index(root.path));
    expect(files, isNotNull, reason: 'the walk never landed');
    expect(index.isIndexed(root.path), isTrue);
  }

  group('drawing what the index knows', () {
    late StreamController<String> changed;
    late RepoFileIndex index;

    ProviderContainer container() {
      changed = StreamController<String>.broadcast();
      addTearDown(changed.close);
      index = RepoFileIndex(
        watcher: DirectoryChangeWatcher(
          debounce: const Duration(milliseconds: 10),
          maxDebounce: const Duration(milliseconds: 30),
          source: (_) => changed.stream,
          recursiveWatchSupported: true,
        ),
      );
      addTearDown(index.dispose);
      return containerWith(index);
    }

    testWidgets('typing finds the repository\'s files', (tester) async {
      write('lib/alpha_widget.dart');
      final scope = container();
      await walkFirst(tester, index);
      await open(tester, scope);

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();

      expect(find.text('alpha_widget.dart'), findsOneWidget);
      expect(find.text('FILES'), findsOneWidget);
    });

    // The audit's missing test 6, at the seam the dialog owns: when the index
    // reports that the tree moved, the open palette has to re-read it.
    //
    // Driven through a scripted index rather than a real walk. The walk's own
    // freshness — noticing a create, a delete, a rename — is covered against a
    // real filesystem in `repo_file_index_test.dart`, and the two halves are
    // joined by driving the built application; a widget test that also waits on
    // real directory I/O ends up asserting the test binding's fake clock rather
    // than the dialog.
    testWidgets('a file written behind the open palette becomes findable', (
      tester,
    ) async {
      final index = _ScriptedIndex(['lib/alpha_widget.dart']);
      addTearDown(index.dispose);
      await open(tester, containerWith(index));

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();
      expect(find.text('alpha_widget.dart'), findsOneWidget);
      expect(find.text('alpha_written_later.dart'), findsNothing);

      // An agent writes a file while quick open is up; the watcher notices.
      index.treeBecame(root.path, [
        'lib/alpha_widget.dart',
        'lib/alpha_written_later.dart',
      ]);
      await tester.pumpAndSettle();

      expect(
        find.text('alpha_written_later.dart'),
        findsOneWidget,
        reason: 'no restart, no reopen — the palette refreshed itself',
      );
      expect(find.text('alpha_widget.dart'), findsOneWidget);
    });

    testWidgets('a file deleted behind the open palette stops being offered', (
      tester,
    ) async {
      final index = _ScriptedIndex([
        'lib/alpha_widget.dart',
        'lib/alpha_doomed.dart',
      ]);
      addTearDown(index.dispose);
      await open(tester, containerWith(index));

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();
      expect(find.text('alpha_doomed.dart'), findsOneWidget);

      index.treeBecame(root.path, ['lib/alpha_widget.dart']);
      await tester.pumpAndSettle();

      expect(
        find.text('alpha_doomed.dart'),
        findsNothing,
        reason: 'offering a file that is gone leads to a failed open',
      );
      expect(find.text('alpha_widget.dart'), findsOneWidget);
    });

    testWidgets('a repository with no matching files says nothing matches', (
      tester,
    ) async {
      write('lib/unrelated.dart');
      final scope = container();
      await walkFirst(tester, index);
      await open(tester, scope);

      await tester.enterText(find.byType(TextField), 'zzzqqq');
      await tester.pumpAndSettle();

      expect(find.text('Nothing matches.'), findsOneWidget);
    });
  });

  group('letting go of a walk', () {
    testWidgets('closing the palette cancels the walk it started', (
      tester,
    ) async {
      final index = _HeldIndex();
      addTearDown(index.dispose);
      await open(tester, containerWith(index));

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();
      expect(index.asked, [root.path]);

      // Escape out of the dialog the way the user does.
      Navigator.of(tester.element(find.byType(TextField))).pop();
      await tester.pumpAndSettle();

      expect(index.cancelled, [
        root.path,
      ], reason: 'nobody is waiting on that walk any more');
    });

    testWidgets('switching repository abandons the walk for the old one', (
      tester,
    ) async {
      final index = _HeldIndex();
      addTearDown(index.dispose);
      final other = '${root.path}_other';
      var selected = root.path;

      final container = await open(
        tester,
        ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(database: db),
            quickOpenFileRootProvider.overrideWith((ref) => selected),
            repoFileIndexProvider.overrideWithValue(index),
          ],
        ),
      );

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();
      expect(index.asked, [root.path]);

      // The shell selects a different repository under the open palette.
      selected = other;
      container.invalidate(quickOpenFileRootProvider);
      await tester.enterText(find.byType(TextField), 'alphab');
      await tester.pumpAndSettle();

      expect(index.cancelled, [root.path]);
      expect(index.asked, [root.path, other]);
    });
  });
}

/// An index whose contents the test sets directly, so the dialog's reaction to
/// a refresh can be asserted without waiting on a real directory walk.
class _ScriptedIndex extends RepoFileIndex {
  _ScriptedIndex(this._onDisk)
    : super(watcher: DirectoryChangeWatcher(recursiveWatchSupported: false));

  List<String> _onDisk;
  List<String>? _read;
  final StreamController<String> _reports = StreamController.broadcast();
  var _fresh = false;

  @override
  Stream<String> get changes => _reports.stream;

  @override
  bool isIndexed(String root) => _read != null;

  @override
  bool isFresh(String root) => _fresh;

  @override
  List<IndexedFile> cached(String root) => [
    for (final path in _read ?? const <String>[])
      IndexedFile(relativePath: path, hostPath: '$root/$path'),
  ];

  /// A walk: it reads what is on disk now and reports what it found.
  @override
  Future<List<IndexedFile>> index(String root) async {
    _read = _onDisk;
    _fresh = true;
    _reports.add(root);
    return cached(root);
  }

  /// What the watcher does in production: the tree moved, so what is cached is
  /// no longer what a walk would find.
  void treeBecame(String root, List<String> paths) {
    _onDisk = paths;
    _fresh = false;
    _reports.add(root);
  }

  @override
  void dispose() {
    _reports.close();
    super.dispose();
  }
}

/// An index whose walk never lands, so what the dialog does with a walk *in
/// flight* can be asserted without racing a real filesystem.
class _HeldIndex extends RepoFileIndex {
  _HeldIndex()
    : super(watcher: DirectoryChangeWatcher(recursiveWatchSupported: false));

  final List<String> asked = [];
  final List<String> cancelled = [];
  final Completer<List<IndexedFile>> _never = Completer();

  @override
  bool isFresh(String root) => false;

  @override
  Future<List<IndexedFile>> index(String root) {
    asked.add(root);
    return _never.future;
  }

  @override
  void cancel(String root) {
    cancelled.add(root);
    super.cancel(root);
  }
}
