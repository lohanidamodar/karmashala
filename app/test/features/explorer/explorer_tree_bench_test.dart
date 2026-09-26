@Tags(['cost'])
library;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_state.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_tree_rows.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/rows.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

/// **The Explorer at 500 projects and 5,000 sessions: what is built, and how
/// long a frame of it takes.**
///
/// The timings are *printed*, never asserted — the suite runs beside other
/// work, and a wall-clock bound is a reading of the machine (see
/// `scale_harness.dart`). What is asserted is the half that is countable: how
/// many rows a screen inflates whatever the workspace holds, that a fling
/// issues no statement per row it passes that a first build did not, and that
/// a status tick and a fold do not rebuild the rows around them.
const _projects = 500;
const _sessionsEach = 10;
const _contexts = 10;

/// A screen of 900px holds under forty one-line rows; the bound is generous so
/// a density change is not a failing test, and far under the 5,500 in the tree.
const _rowBound = 90;

void main() {
  CountingDatabase seed() {
    final db = CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(posixEnv());
    AgentInstallationDao(db).insert(agentInstallation());
    for (var c = 0; c < _contexts; c++) {
      WorkspaceDao(
        db,
      ).insert(Workspace(id: 'w$c', name: 'Context $c', createdAt: testTime));
    }
    final projects = ProjectDao(db);
    final repositories = RepositoryDao(db);
    final sessions = SessionDao(db);
    db.execute('BEGIN');
    for (var p = 0; p < _projects; p++) {
      final path = '/Users/me/Documents/projects/client-$p/workspace-$p';
      projects.insert(
        project(
          id: 'p$p',
          name: 'Project $p',
          path: path,
          workspaceId: 'w${p % _contexts}',
        ),
      );
      repositories.insert(
        repository(id: 'r$p', projectId: 'p$p', name: 'repo', path: path),
      );
      for (var s = 0; s < _sessionsEach; s++) {
        sessions.insert(
          Session(
            id: 'p$p-s$s',
            repositoryId: 'r$p',
            agentInstallationId: 'a1',
            title: 'Session $s of project $p',
            useWorktree: false,
            status: s == 0 ? SessionStatus.running : SessionStatus.completed,
            createdAt: testTime.add(Duration(minutes: s)),
            externalSessionId: 'ext-$p-$s',
          ),
        );
      }
    }
    db.execute('COMMIT');
    return db;
  }

  Future<({ProviderContainer container, CountingDatabase db, int firstUs})>
  pump(WidgetTester tester, {required int open}) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = seed();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(
              responder: (_) =>
                  const CommandResult(exitCode: 0, stdout: '', stderr: ''),
            ),
          ),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final expanded = container.read(explorerExpandedProjectsProvider.notifier);
    // The first projects of the first context, so they are the rows on screen.
    for (var p = 0; p < open; p++) {
      expanded.open(open == _projects ? 'p$p' : 'p${p * _contexts}');
    }
    db.reset();
    final watch = Stopwatch()..start();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    watch.stop();
    return (container: container, db: db, firstUs: watch.elapsedMicroseconds);
  }

  /// The follow-up service judges every ended session once per launch, with a
  /// statement each (`follow_up_service.dart`). It is the launch's cost and not
  /// the tree's, so it is counted apart.
  int explorerStatements(CountingDatabase db) =>
      db.statements.where((sql) => !sql.contains('verification_runs')).length;

  int rows(WidgetTester tester) =>
      tester.widgetList(find.byType(ExplorerTreeRow)).length;

  /// One fling down the list, pumped at 60Hz until it stops.
  Future<({int frames, int us, int worstUs})> fling(WidgetTester tester) async {
    await tester.fling(
      find.byType(ListView),
      const Offset(0, -600),
      8000,
      warnIfMissed: false,
    );
    var frames = 0;
    var worst = 0;
    final total = Stopwatch()..start();
    while (tester.binding.hasScheduledFrame && frames < 600) {
      final frame = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      frame.stop();
      if (frame.elapsedMicroseconds > worst) worst = frame.elapsedMicroseconds;
      frames++;
    }
    total.stop();
    return (frames: frames, us: total.elapsedMicroseconds, worstUs: worst);
  }

  testWidgets('500 projects, folded: first build, fling, search', (
    tester,
  ) async {
    final harness = await pump(tester, open: 0);
    final firstStatements = explorerStatements(harness.db);
    final inflated = rows(tester);
    expect(inflated, lessThanOrEqualTo(_rowBound));
    expect(find.byType(ExplorerProjectRow), findsWidgets);

    var recomputes = 0;
    harness.container.listen(
      explorerTreeProvider,
      (_, _) => recomputes++,
      fireImmediately: false,
    );

    harness.db.reset();
    final flung = await fling(tester);
    expect(rows(tester), lessThanOrEqualTo(_rowBound));
    expect(recomputes, 0, reason: 'scrolling is not a change of shape');
    final flingStatements = explorerStatements(harness.db);

    // Typed a character at a time, the way it arrives — and from where the
    // fling left the list, which is the expensive place to be when the tree
    // under it gets shorter.
    harness.db.reset();
    final typed = <int>[];
    var text = '';
    for (final char in 'Project 49'.split('')) {
      text += char;
      final watch = Stopwatch()..start();
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      watch.stop();
      typed.add(watch.elapsedMicroseconds);
    }
    expect(find.text('Project 49'), findsWidgets);
    // Three keys changed what is drawn — the first, from a scrolled list, and
    // the two that narrowed it — and each built a screenful. A list that
    // crossed the distance instead built every match: 602 statements here.
    expect(explorerStatements(harness.db), lessThan(300));
    // ignore: avoid_print
    print(
      'EXPLORER-BENCH folded projects=$_projects '
      'first_build_us=${harness.firstUs} first_statements=$firstStatements '
      'rows_inflated=$inflated '
      'fling_frames=${flung.frames} fling_us_per_frame='
      '${flung.frames == 0 ? 0 : flung.us ~/ flung.frames} '
      'fling_worst_us=${flung.worstUs} fling_statements=$flingStatements '
      'search_us_per_key=${typed.reduce((a, b) => a + b) ~/ typed.length} '
      'search_worst_us=${typed.reduce((a, b) => a > b ? a : b)} '
      'search_statements=${explorerStatements(harness.db)} '
      'search_tree_recomputes=$recomputes',
    );
  });

  // Ten open is a working day; every one open is the tree at its largest.
  for (final open in [10, _projects]) {
    testWidgets('5,000 sessions, $open projects open: first build, fling, '
        'fold, status tick', (tester) async {
      final harness = await pump(tester, open: open);
      final firstStatements = explorerStatements(harness.db);
      final inflated = rows(tester);
      expect(inflated, lessThanOrEqualTo(_rowBound));
      expect(
        harness.container.read(explorerTreeProvider).nodes.length,
        greaterThan(open * _sessionsEach),
      );

      // A status tick on a row that is on screen: that row, and its project's
      // header, and no other session card.
      final visible = tester
          .widgetList<SessionCard>(find.byType(SessionCard))
          .toList();
      expect(visible, isNotEmpty);
      final target = tester
          .widgetList<ExplorerNativeSessionRow>(
            find.byType(ExplorerNativeSessionRow),
          )
          .map((row) => row.node.session)
          .firstWhere((s) => s.status == SessionStatus.completed);
      Map<String, int> identities() => {
        for (final card in tester.widgetList<SessionCard>(
          find.byType(SessionCard),
        ))
          card.title: identityHashCode(card),
      };
      final before = identities();
      SessionDao(harness.db).updateStatus(target.id, SessionStatus.idle);
      harness.db.reset();
      final tick = Stopwatch()..start();
      harness.container
          .read(sessionsRevisionProvider.notifier)
          .changed(SessionChange.statusChanged(target.id));
      await tester.pump();
      tick.stop();
      final tickStatements = explorerStatements(harness.db);
      final after = identities();
      // And nine more, there and back, because one frame is mostly noise.
      final ticks = Stopwatch()..start();
      for (var i = 0; i < 9; i++) {
        SessionDao(harness.db).updateStatus(
          target.id,
          i.isEven ? SessionStatus.completed : SessionStatus.idle,
        );
        harness.container
            .read(sessionsRevisionProvider.notifier)
            .changed(SessionChange.statusChanged(target.id));
        await tester.pump();
      }
      ticks.stop();
      final rebuilt = [
        for (final entry in after.entries)
          if (before[entry.key] != entry.value) entry.key,
      ];
      expect(rebuilt, [target.title]);

      // Folding one project: the tree is recomputed once, and the rows kept are
      // kept by key.
      final project = tester
          .widgetList<ExplorerProjectRow>(find.byType(ExplorerProjectRow))
          .first
          .project;
      harness.db.reset();
      final fold = Stopwatch()..start();
      harness.container
          .read(explorerExpandedProjectsProvider.notifier)
          .toggle(project.id);
      await tester.pump();
      fold.stop();
      final foldStatements = explorerStatements(harness.db);
      expect(rows(tester), lessThanOrEqualTo(_rowBound));
      final folds = Stopwatch()..start();
      for (var i = 0; i < 9; i++) {
        harness.container
            .read(explorerExpandedProjectsProvider.notifier)
            .toggle(project.id);
        await tester.pump();
      }
      folds.stop();

      final flung = await fling(tester);
      expect(rows(tester), lessThanOrEqualTo(_rowBound));

      // ignore: avoid_print
      print(
        'EXPLORER-BENCH open=$open projects=$_projects '
        'sessions=${_projects * _sessionsEach} '
        'first_build_us=${harness.firstUs} first_statements=$firstStatements '
        'rows_inflated=$inflated '
        'fling_frames=${flung.frames} fling_us_per_frame='
        '${flung.frames == 0 ? 0 : flung.us ~/ flung.frames} '
        'fling_worst_us=${flung.worstUs} '
        'status_tick_us=${tick.elapsedMicroseconds} '
        'status_tick_avg_us=${(tick.elapsedMicroseconds + ticks.elapsedMicroseconds) ~/ 10} '
        'status_tick_statements=$tickStatements '
        'fold_us=${fold.elapsedMicroseconds} '
        'fold_avg_us=${(fold.elapsedMicroseconds + folds.elapsedMicroseconds) ~/ 10} '
        'fold_statements=$foldStatements',
      );
    });
  }
}
