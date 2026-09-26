import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_git/repositories.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What opening a project in the Explorer costs in CLI-store scans.**
///
/// The owner, profiling: *"still lags and during the whole time the explorer
/// shows loading icon, what is it loading on every expand?"* It was this — a
/// full walk of every CLI store, started by the expand **and** by the selection
/// the expand performs, so a click cost two and five open projects cost five
/// concurrent walks of a store that is 663 files across `\\wsl.localhost`.
///
/// Counted, never timed: a scan either happened or it did not, and that is
/// deterministic on any machine.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late ProviderContainer container;
  late int scans;

  EnvironmentPath root(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer();
    server.environmentRows.upsert(
  localHostEnvironment(FixedClock(testTime).nowUtc()),
);
    scans = 0;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // The seam the whole file counts on: one call is one walk of every
        // store, whatever it was asked about.
        autoImportRunnerProvider.overrideWithValue((_) async {
          scans++;
          return const ImportSummary();
        }),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  void seed({int projects = 3}) {
    for (var i = 0; i < projects; i++) {
      server.projectRows.insert(
        Project(
          id: 'p$i',
          name: 'Project $i',
          root: root('C:\\work\\p$i'),
          createdAt: testTime,
        ),
      );
      server.repositoryRows.insert(
        Repository(
          id: 'r$i',
          projectId: 'p$i',
          name: 'repo$i',
          path: root('C:\\work\\p$i'),
          createdAt: testTime,
        ),
      );
    }
  }

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: ExplorerPanel()),
    ),
  );

  testWidgets('expanding every project scans nothing', (tester) async {
    seed();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final cards = find.byType(ProjectCard);
    expect(cards, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      await tester.tap(cards.at(i));
      await tester.pumpAndSettle();
    }
    // And collapse-then-expand, which used to buy a second walk each.
    await tester.tap(cards.first);
    await tester.pumpAndSettle();
    await tester.tap(cards.first);
    await tester.pumpAndSettle();

    // ignore: avoid_print
    print('EXPLORER-EXPAND projects=3 expands=5 scans=$scans');
    expect(
      scans,
      0,
      reason: 'expanding is two indexed DAO reads; it reads no store at all',
    );
  });

  testWidgets('selecting a project scans nothing either', (tester) async {
    seed();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      container.read(selectedProjectIdProvider.notifier).select('p$i');
      await tester.pumpAndSettle();
    }

    expect(scans, 0);
  });

  testWidgets('the lifecycle import is one scan, however often it is asked', (
    tester,
  ) async {
    seed();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final controller = container.read(projectsControllerProvider.notifier);
    await Future.wait([
      controller.importCliSessionsOnce(),
      controller.importCliSessionsOnce(),
    ]);
    await controller.importCliSessionsOnce();

    // ignore: avoid_print
    print('EXPLORER-LIFECYCLE asks=3 projects=3 scans=$scans');
    expect(
      scans,
      1,
      reason: 'one walk of the stores for the whole workspace, once per run',
    );
  });

  testWidgets('the refresh in the project menu is the way to re-scan', (
    tester,
  ) async {
    seed(projects: 1);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProjectCard), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Refresh CLI sessions'),
      findsOneWidget,
      reason: 'the owner asked for the refresh to stay in the popup',
    );
    await tester.tap(find.textContaining('Refresh CLI sessions'));
    await tester.pumpAndSettle();

    expect(scans, 1);
  });

  group('staleness is visible', () {
    // Both form factors: the label grew, and a project row is drawn stacked on
    // a phone and on one line on a desktop.
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('the refresh says how old the reading is at $size', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        seed(projects: 1);
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();

        await tester.tap(find.byType(ProjectCard), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(
          find.text('Refresh CLI sessions · never checked'),
          findsOneWidget,
          reason: '§19: before a reading, say there is none',
        );
        await tester.tap(find.text('Refresh CLI sessions · never checked'));
        await tester.pumpAndSettle();

        await tester.tap(find.byType(ProjectCard), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(
          find.text('Refresh CLI sessions · checked just now'),
          findsOneWidget,
        );
      });
    }

    testWidgets('an empty project does not claim it has no sessions', (
      tester,
    ) async {
      seed(projects: 1);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProjectCard));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('the CLI stores have not been checked'),
        findsOneWidget,
        reason: '"no sessions yet" is a claim about stores nobody has read',
      );

      await container
          .read(projectsControllerProvider.notifier)
          .importCliSessionsOnce();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No sessions yet — start one'),
        findsOneWidget,
      );
    });
  });
}
