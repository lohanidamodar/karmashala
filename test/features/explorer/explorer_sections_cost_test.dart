import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/session_card.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

/// **What saved sections cost, in the two units that matter.**
///
/// The gate this feature was written against is
/// `test/features/scale/quiet_soak_cost_test.dart`, which pins **zero**
/// database statements over 180 autosave ticks at a hundred idle panes. A
/// filter that asked git, `gh` or SQLite one question per session per rebuild
/// would have broken it, and that gate is worth more than this feature — so the
/// matching reads caches other surfaces filled and fills none of its own.
///
/// Two claims, counted rather than timed, in the shape
/// `project_attention_cost_test.dart` and `checkout_scale_cost_test.dart`
/// established:
///
/// 1. **Matching is O(1) in database statements and O(0) in processes.**
///    Filing a hundred sessions into four sections reads the database exactly
///    as often as filing one — three unfiltered sweeps, on change only — and
///    starts no subprocess at all. Re-reading the answer, the way a rebuilding
///    sidebar re-reads it, costs nothing.
/// 2. **A collapsed section builds no rows and matches nothing.** Not "less":
///    nothing. The candidate sweep, the fact table and the assignment are all
///    `autoDispose` and reachable only from an expanded section's body, so with
///    the sidebar folded shut none of them exist.
/// The three unfiltered sweeps `sectionCandidatesProvider` makes — the only
/// statements saved sections added to the app.
bool _isSectionSweep(String sql) =>
    sql.startsWith('SELECT * FROM sessions ORDER BY') ||
    sql.startsWith('SELECT * FROM repositories ORDER BY') ||
    sql.startsWith('SELECT * FROM imported_sessions WHERE NOT EXISTS');

void main() {
  const scale = [1, 10, 100];

  /// A workspace of [count] sessions on one repository, a third of them failed
  /// so the seeded "Ended in failure" section has something to hold.
  CountingDatabase seed(int count) {
    final db = CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(db).insert(
      repository(id: 'r1', projectId: 'p1', name: 'hub', path: r'C:\hub'),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    for (var i = 0; i < count; i++) {
      SessionDao(db).insert(
        session(
          id: 's$i',
          title: 'Session $i',
          status: i % 3 == 0 ? SessionStatus.failed : SessionStatus.running,
        ),
      );
    }
    return db;
  }

  ProviderContainer mount(CountingDatabase db, FakeCommandRunner git) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        // Stubbed for the reason `quiet_soak_cost_test` gives: the live one
        // fans into the transcript-stat cycle, which is a disk measurement
        // belonging to another gate.
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('matching a workspace', () {
    final mountStatements = <int, int>{};
    final tickStatements = <int, int>{};
    final processes = <int, int>{};

    for (final count in scale) {
      test('of $count sessions files them without asking anything new', () async {
        final db = seed(count);
        addTearDown(db.close);
        final git = FakeCommandRunner();
        final container = mount(db, git);

        // Every section open — the most expensive shape this feature has.
        final controller = container.read(explorerSectionsProvider.notifier);
        for (final section in container.read(explorerSectionsProvider)) {
          controller.setCollapsed(section.id, false);
        }
        db.reset();
        git.requests.clear();

        container.listen(explorerSectionAssignmentProvider, (_, _) {});
        await container.pump();
        final assignment = container.read(explorerSectionAssignmentProvider);
        mountStatements[count] = db.reads.length;

        // The rows really were filed, so the numbers below are the cost of
        // doing the work rather than the cost of skipping it.
        final failed = assignment['section-ended-in-failure']!;
        expect(failed.length, (count + 2) ~/ 3);

        db.reset();
        git.requests.clear();
        // A second of frames over a sidebar where nothing moved, re-read the
        // way a rebuilding widget re-reads it.
        for (var frame = 0; frame < 180; frame++) {
          container.read(explorerSectionAssignmentProvider);
        }
        await container.pump();
        tickStatements[count] = db.count;
        processes[count] = git.requests.length;

        // ignore: avoid_print
        print(
          'SECTION-MATCH sessions=$count mount_reads=${mountStatements[count]} '
          'tick_statements=${db.count} processes=${git.requests.length}',
        );
        expect(
          db.statements,
          isEmpty,
          reason:
              'a sidebar nobody touched must not re-query: ${db.statements}',
        );
        expect(
          git.requests,
          isEmpty,
          reason:
              'matching must never start a process — that is the whole '
              'constraint',
        );
      });
    }

    test('costs the same database at a hundred sessions as at one', () {
      expect(mountStatements.keys, containsAll(scale));
      // Three sweeps — sessions, imported sessions, repositories — plus what
      // the settings row and the sections themselves cost. A constant, because
      // nothing here is read per session.
      expect(
        mountStatements.values.toSet().length,
        1,
        reason:
            'filing a hundred sessions must read the database exactly as often '
            'as filing one: $mountStatements',
      );
      expect(tickStatements.values.toSet(), orderedEquals([0]));
      expect(processes.values.toSet(), orderedEquals([0]));
    });
  });

  group('a collapsed section', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      CountingDatabase db,
    ) async {
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    for (final count in scale) {
      testWidgets('over $count sessions builds no rows and matches nothing', (
        tester,
      ) async {
        final db = seed(count);
        addTearDown(db.close);
        final container = await pump(tester, db);

        // The four seeded sections are all there, folded shut.
        expect(find.text('Pinned'), findsOneWidget);
        expect(find.text('Ended in failure'), findsOneWidget);
        db.reset();

        // ignore: avoid_print
        print(
          'SECTION-COLLAPSED sessions=$count '
          'cards=${tester.widgetList(find.byType(SessionCard)).length} '
          'candidates_mounted=${container.exists(sectionCandidatesProvider)}',
        );
        expect(
          tester.widgetList(find.byType(SessionCard)),
          isEmpty,
          reason: 'a folded section draws nothing, as a folded project does',
        );
        expect(
          container.exists(sectionCandidatesProvider),
          isFalse,
          reason:
              'nothing may sweep the session list to answer a question the '
              'user has not asked',
        );
        expect(
          container.exists(explorerSectionAssignmentProvider),
          isFalse,
          reason: 'no rule may run for a section nobody has opened',
        );
      });
    }

    /// Opens the seeded "Ended in failure" section over a workspace of
    /// [count] sessions and reports what that cost.
    Future<({int statements, int sweeps, int cards, int members})> open(
      WidgetTester tester,
      int count,
    ) async {
      final db = seed(count);
      addTearDown(db.close);
      final container = await pump(tester, db);
      db.reset();

      await tester.tap(find.text('Ended in failure'));
      await tester.pumpAndSettle();

      return (
        statements: db.count,
        // The matching's own reads: the three unfiltered sweeps
        // [sectionCandidatesProvider] makes. Counted apart from everything
        // else because they are the only statements this feature added.
        sweeps: db.statements.where(_isSectionSweep).length,
        cards: tester.widgetList(find.byType(SessionCard)).length,
        members: container
            .read(explorerSectionMembersProvider('section-ended-in-failure'))
            .length,
      );
    }

    /// **The shape, not the number.**
    ///
    /// Opening a section costs two separable things, and separating them is the
    /// point of this test. The **matching** costs one sweep of each of the three
    /// tables, whatever the workspace holds — that is the number this feature is
    /// answerable for, and it is flat. The **rows** cost what a session card has
    /// always cost, charged when a card is *inflated*, which is the rule the
    /// Explorer's tree already lives by and which
    /// `explorer_panel_scale_test.dart` governs.
    ///
    /// So ten times the sessions buys ten times the members and neither ten
    /// times the queries nor ten times the cards. The failure this catches is
    /// the one the old checkout rows made: reaching for a fact **per session in
    /// the workspace** rather than per session on screen would show up here as
    /// a number that tracked the workspace.
    ///
    /// Two `testWidgets` rather than one measuring both, because a second
    /// `pumpWidget` in one test tears the first tree down without draining what
    /// it armed, and `flutter_test`'s pending-timer check — rightly — calls
    /// that a failure.
    final opened =
        <int, ({int statements, int sweeps, int cards, int members})>{};

    for (final count in [30, 300]) {
      testWidgets('opened over $count sessions', (tester) async {
        final result = await open(tester, count);
        opened[count] = result;
        // ignore: avoid_print
        print(
          'SECTION-OPEN sessions=$count statements=${result.statements} '
          'sweeps=${result.sweeps} cards=${result.cards} '
          'members=${result.members}',
        );
        expect(
          result.cards,
          greaterThan(0),
          reason: 'opening it has to actually show the work',
        );
        expect(
          result.sweeps,
          3,
          reason:
              'matching reads the three tables once each, and a bigger '
              'workspace does not make that four',
        );
      });
    }

    test('so opening one costs a screenful, not a workspace', () {
      expect(opened.keys, containsAll([30, 300]));
      final small = opened[30]!;
      final large = opened[300]!;
      expect(small.members, 10);
      expect(large.members, 100, reason: 'ten times the work is really there');
      expect(
        large.statements,
        lessThan(small.statements * 2),
        reason:
            'ten times the sessions must not be ten times the queries: '
            '${small.statements} vs ${large.statements}',
      );
    });
  });
}
