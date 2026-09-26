import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/presentation/workspaces_dialog.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

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

  late CountingMachine db;
  late ProviderContainer container;
  late FakeDataServer server;

  setUp(() async {
    db = CountingMachine();
    server = FakeDataServer(clock: () => testTime);
    server.environmentRows.upsert(windowsEnv());
    container = ProviderContainer(
      overrides: [
        await server.override(),
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

  /// The owner's own scale: 31 projects and four contexts.
  Future<void> seed() async {
    final workspaces = [
      for (final name in const [
        'Personal',
        'PopupBits',
        'Appwrite',
        'Game dev',
      ])
        (await createContext(container, name)).id,
    ];
    for (var i = 0; i < projectCount; i++) {
      server.projectRows.insert(
        Project(
          id: 'p$i',
          name: 'Project $i',
          root: EnvironmentPath(environmentId: 'windows', path: r'C:\src\p$i'),
          createdAt: testTime,
          workspaceId: i.isEven ? workspaces[i % 4] : null,
        ),
      );
    }
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
    await seed();
    await tester.pumpWidget(dialogApp());
    await tester.pumpAndSettle();

    final before = pickerIdentities(tester);
    expect(
      before,
      hasLength(projectCount),
      reason: 'every project row must be on screen to be counted',
    );

    db.reset();
    final asked = server.requests.length;
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
      'writes=${db.writes} reads=${db.reads} '
      'requests=${server.requests.sublist(asked)}',
    );

    expect(
      container.read(workspacesControllerProvider).map((w) => w.name),
      contains('Client work'),
    );
    expect(
      server.requests.sublist(asked),
      hasLength(1),
      reason: 'one write for the context that was created, and nothing else',
    );
    expect(
      db.reads,
      isEmpty,
      reason:
          'the context is the server\'s to store; the app asks it nothing '
          'back, least of all the project list',
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
    await seed();
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
    expect(db.statements, isEmpty, reason: 'a keystroke is not a request');
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
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    for (var i = 0; i < projectCount; i++) {
      server.projectRows.insert(
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
      // A row announced again, unchanged: the panel rebuilds for it.
      server.projectRows.update(server.projectRows.getById('p0')!);
      await tester.pumpAndSettle();
      return db.count;
    }

    final bare = await rebuildCost();
    // "Which agents are installed here" used to be asked once per row on every
    // rebuild: 31 identical queries. A row's menu now asks it when it opens.
    expect(
      db.statements.where((kind) => kind.startsWith('agents.')).length,
      0,
      reason: 'a rebuild must not resolve menus nobody opened',
    );

    for (final name in const ['Personal', 'PopupBits', 'Appwrite', 'Games']) {
      await createContext(container, name);
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
