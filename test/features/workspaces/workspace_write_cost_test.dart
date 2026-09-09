import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/projects/application/project_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/presentation/workspaces_dialog.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What creating a context costs, counted.**
///
/// The owner reported "creating context was lagging". Counted, never timed —
/// wall-clock over a few milliseconds fails whenever the machine is busy, and
/// the two things that can actually be slow here are both countable: how many
/// statements reach SQLite, and how many rows of the dialog are rebuilt.
///
/// The dialog draws every one of the workspace's projects (deliberately — a
/// lazy viewport disposes rows and breaks Tab), so "one more context" must not
/// mean "rebuild 31 project rows, twice".
void main() {
  const projectCount = 31;

  late _CountingDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = _CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // The Explorer case below mounts session cards, and a widget test must
        // never spawn `git` or walk a CLI store.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  /// The owner's own scale: 31 projects and four contexts.
  void seed() {
    final dao = container.read(projectDaoProvider);
    final workspaces = [
      for (final name in const ['Personal', 'PopupBits', 'Appwrite', 'Game dev'])
        container.read(workspacesControllerProvider.notifier).create(name).id,
    ];
    for (var i = 0; i < projectCount; i++) {
      dao.insert(
        Project(
          id: 'p$i',
          name: 'Project $i',
          root: EnvironmentPath(environmentId: 'windows', path: r'C:\src\p$i'),
          createdAt: testTime,
          workspaceId: i.isEven ? workspaces[i % 4] : null,
        ),
      );
    }
    container.read(projectsControllerProvider.notifier).refreshFromStore();
  }

  Widget dialogApp() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: WorkspacesDialog()),
    ),
  );

  /// Identity of every project row's context picker, so a rebuild is countable
  /// without instrumenting the widget under test.
  List<int> pickerIdentities(WidgetTester tester) => [
    for (final button in tester.widgetList<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    ))
      identityHashCode(button),
  ];

  int changed(List<int> before, List<int> after) {
    if (before.length != after.length) return after.length;
    var count = 0;
    for (var i = 0; i < before.length; i++) {
      if (before[i] != after[i]) count++;
    }
    return count;
  }

  testWidgets('creating a context rebuilds no project row', (tester) async {
    tester.view.physicalSize = const Size(720, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    seed();
    await tester.pumpWidget(dialogApp());
    await tester.pumpAndSettle();

    final before = pickerIdentities(tester);
    expect(
      before,
      hasLength(projectCount),
      reason: 'every project row must be on screen to be counted',
    );

    db.reset();
    await tester.enterText(
      find.widgetWithText(TextField, 'New context'),
      'Client work',
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add'));
    await tester.pumpAndSettle();

    final after = pickerIdentities(tester);
    final rebuilt = changed(before, after);
    // ignore: avoid_print
    print(
      'CONTEXT-CREATE projects=$projectCount rows-rebuilt=$rebuilt '
      'writes=${db.writes} reads=${db.reads}',
    );

    expect(
      container.read(workspacesControllerProvider).map((w) => w.name),
      contains('Client work'),
    );
    expect(
      db.writes,
      1,
      reason: 'one INSERT for the row that was created, and nothing else',
    );
    expect(
      db.reads,
      1,
      reason: 'one re-read of the context list — never the project list',
    );
    expect(
      rebuilt,
      0,
      reason:
          'a new context changes nothing about any project, so no project row '
          'may be rebuilt — 31 of them twice over is the reported lag',
    );
  });

  testWidgets('typing a context name rebuilds nothing at all', (tester) async {
    tester.view.physicalSize = const Size(720, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    seed();
    await tester.pumpWidget(dialogApp());
    await tester.pumpAndSettle();

    final before = pickerIdentities(tester);
    db.reset();
    for (final fragment in const ['C', 'Cl', 'Cli', 'Clie', 'Clien']) {
      await tester.enterText(
        find.widgetWithText(TextField, 'New context'),
        fragment,
      );
      await tester.pump();
    }

    final rebuilt = changed(before, pickerIdentities(tester));
    // ignore: avoid_print
    print(
      'CONTEXT-TYPING projects=$projectCount rows-rebuilt=$rebuilt '
      'statements=${db.statements}',
    );
    expect(db.statements, 0, reason: 'a keystroke is not a query');
    expect(rebuilt, 0, reason: 'a keystroke is not a reason to redraw a list');
  });

  /// The Explorer builds its project rows' menus **eagerly**, one per row, so
  /// anything the context items resolve is resolved once per project. They are
  /// resolved once per *build* instead — the contexts and their sizes are read
  /// by the panel and handed down — and this is the measurement that says so.
  testWidgets('the context items on 31 project rows cost no statement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    final dao = container.read(projectDaoProvider);
    for (var i = 0; i < projectCount; i++) {
      dao.insert(
        Project(
          id: 'p$i',
          name: 'Project $i',
          root: EnvironmentPath(
            environmentId: localHostEnvironmentId,
            path: r'C:\src\p$i',
          ),
          createdAt: testTime,
        ),
      );
    }
    container.read(projectsControllerProvider.notifier).refreshFromStore();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    /// One whole rebuild of the panel, counted.
    Future<int> rebuildCost() async {
      db.reset();
      container.read(projectsControllerProvider.notifier).refreshFromStore();
      await tester.pumpAndSettle();
      return db.statements;
    }

    final bare = await rebuildCost();
    // The project menus are built eagerly per row, and "which agents are
    // installed here" used to be asked inside that loop: 31 identical queries
    // per rebuild. It is asked once per *environment* now.
    expect(
      db.matching('FROM agent_installations'),
      1,
      reason:
          'one query for the one environment these 31 projects share, not one '
          'query per project row',
    );

    final workspaces = container.read(workspacesControllerProvider.notifier);
    for (final name in const ['Personal', 'PopupBits', 'Appwrite', 'Games']) {
      workspaces.create(name);
    }
    await tester.pumpAndSettle();
    final withContexts = await rebuildCost();

    // ignore: avoid_print
    print(
      'EXPLORER-CONTEXT-MENU projects=$projectCount '
      'rebuild-without-contexts=$bare with-four-contexts=$withContexts',
    );
    expect(
      withContexts,
      bare,
      reason:
          'four contexts on 31 rows must add nothing to a rebuild — not a '
          'count query per context, and certainly not one per row',
    );
  });
}

/// Counts what reaches SQLite; `package:sqlite3` is synchronous, so all of it
/// runs on the UI isolate inside the frame.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int writes = 0;
  int reads = 0;
  final List<String> sql = [];

  int get statements => writes + reads;

  /// How many statements since the last [reset] mentioned [fragment] — so a
  /// claim about *one* query is checkable without counting every other.
  int matching(String fragment) =>
      sql.where((statement) => statement.contains(fragment)).length;

  void reset() {
    writes = 0;
    reads = 0;
    sql.clear();
  }

  @override
  void execute(String statement, [List<Object?> params = const []]) {
    writes++;
    sql.add(statement);
    super.execute(statement, params);
  }

  @override
  List<Map<String, Object?>> query(
    String statement, [
    List<Object?> params = const [],
  ]) {
    reads++;
    sql.add(statement);
    return super.query(statement, params);
  }
}
