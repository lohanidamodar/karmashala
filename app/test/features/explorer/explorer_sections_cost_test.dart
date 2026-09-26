import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/application/explorer_view_mode.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
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
///    as often as filing one — two unfiltered sweeps, on change only — and
///    starts no subprocess at all. Re-reading the answer, the way a rebuilding
///    sidebar re-reads it, costs nothing.
/// 2. **A collapsed section builds no rows and matches nothing.** Not "less":
///    nothing. The candidate sweep, the fact table and the assignment are all
///    `autoDispose` and reachable only from an expanded section's body, so with
///    the sidebar folded shut none of them exist.
/// 3. **What hiding an empty section costs, since it is not nothing.** "Is this
///    section empty" is the same match as "what is in it", so
///    `Settings.hideEmptySections` — on by default — mounts that graph for a
///    sidebar nobody has opened, and claim 2 holds only with the filter off.
///    What the filter buys back is three rows of the user's sidebar that said
///    nothing; what it costs is exactly the bill an open section already paid
///    and not a statement more: the same two sweeps, still flat in the size
///    of the workspace, still no subprocess, still nothing per rebuild — and
///    **not the delivery heartbeat**, which stays gated on a section actually
///    having rows on screen. That last one is not a micro-optimisation: it is
///    the difference between the Explorer being open and the app running a
///    two-minute timer.
/// The two unfiltered sweeps `sectionCandidatesProvider` makes (its checkouts
/// come from the copy of the workspace, not the database) — the only
/// statements saved sections added to the app.
bool _isSectionSweep(String sql) =>
    sql.startsWith('SELECT * FROM sessions ORDER BY') ||
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
      // Two sweeps — sessions, imported sessions — plus what
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
    /// [hideEmpty] is `Settings.hideEmptySections`. **It is the whole subject
    /// of this group**, because it is the one thing that decides whether the
    /// matching graph is mounted for a sidebar nobody has opened: with it off,
    /// nothing below the collapse gate exists; with it on, the sidebar has to
    /// match in order to know which headers are worth a row.
    Future<ProviderContainer> pump(
      WidgetTester tester,
      CountingDatabase db, {
      bool hideEmpty = false,
    }) async {
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
      container
          .read(settingsControllerProvider.notifier)
          .setHideEmptySections(hideEmpty);
      // The tree's spine is the machine; the saved views are the surface
      // these sections are drawn on.
      container.read(explorerShowingViewsProvider.notifier).toggle();
      // The shell's status bar and rail badge keep the attention inbox alive
      // before any row is drawn; a session row reads its unread word from it.
      container.listen(attentionInboxProvider, (_, _) {});
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
        // The matching's own reads: the two unfiltered sweeps
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
    /// point of this test. The **matching** costs one sweep of each of the two
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
          2,
          reason:
              'matching reads the two session tables once each, and a bigger '
              'workspace does not make that three',
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

  /// **The price of the empty filter, counted rather than argued about.**
  ///
  /// This is the group that would catch the regression the feature is one
  /// mistake away from: asking whether a section is empty *per section*, or
  /// *per rebuild*, or by going and measuring something. All three would show
  /// up here as a number that moved.
  ///
  /// Measured as a **difference** rather than as an absolute, because the
  /// Explorer's own tree sweeps the same three tables to draw itself and the
  /// question here is not what the panel costs — it is what turning the filter
  /// on adds to that.
  group('hiding empty sections', () {
    /// Mounts the panel and reports what deciding what to draw cost, counted
    /// from the frame the widget went up.
    Future<({ProviderContainer container, int sweeps, int cards})> pump(
      WidgetTester tester,
      int count, {
      required bool hideEmpty,
    }) async {
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = seed(count);
      addTearDown(db.close);
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
      container
          .read(settingsControllerProvider.notifier)
          .setHideEmptySections(hideEmpty);
      db.reset();
      // The tree's spine is the machine; the saved views are the surface
      // these sections are drawn on.
      container.read(explorerShowingViewsProvider.notifier).toggle();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
      return (
        container: container,
        sweeps: db.statements.where(_isSectionSweep).length,
        cards: tester.widgetList(find.byType(SessionCard)).length,
      );
    }

    final on = <int, int>{};
    final off = <int, int>{};

    for (final count in scale) {
      testWidgets('over $count sessions, filter off', (tester) async {
        final result = await pump(tester, count, hideEmpty: false);
        off[count] = result.sweeps;
        // Every seeded section is there, folded shut and saying nothing about
        // what it holds — the shape this feature shipped in.
        expect(find.text('Pinned'), findsOneWidget);
        expect(find.text('Checks failing'), findsOneWidget);
        expect(find.text('Ended in failure'), findsOneWidget);
      });

      testWidgets('over $count sessions, filter on', (tester) async {
        final result = await pump(tester, count, hideEmpty: true);
        on[count] = result.sweeps;

        // A third of the workspace failed, so exactly one seeded section has
        // anything in it — and the filter really did take the other three off
        // the sidebar rather than merely being switched on.
        expect(find.text('Ended in failure'), findsOneWidget);
        expect(find.text('Checks failing'), findsNothing);
        expect(find.text('Awaiting input'), findsNothing);
        expect(find.text('Pinned'), findsNothing);
        expect(
          result.cards,
          0,
          reason:
              'knowing a section is not empty is not the same as drawing it: '
              'the surviving header is still folded shut',
        );
        expect(
          result.container.exists(deliveryPollProvider),
          isFalse,
          reason:
              "the Explorer being open must not start the app's delivery "
              'heartbeat — the filter needs to know what is empty, not to '
              'keep asking',
        );
      });
    }

    test('costs two sweeps, and the same two at a hundred as at one', () {
      expect(on.keys, containsAll(scale));
      expect(off.keys, containsAll(scale));
      // ignore: avoid_print
      print('SECTION-FILTER sweeps on=$on off=$off');
      expect(
        off.values.toSet().length,
        1,
        reason: 'the panel itself is flat to begin with: $off',
      );
      for (final count in scale) {
        expect(
          on[count]! - off[count]!,
          2,
          reason:
              'deciding which sections are worth a row reads the two tables '
              'once each and no more, at $count sessions: '
              '${on[count]} against ${off[count]}',
        );
      }
    });

    testWidgets('and nothing at all on a sidebar nobody has touched', (
      tester,
    ) async {
      final result = await pump(tester, 100, hideEmpty: true);
      final db = result.container.read(databaseProvider) as CountingDatabase;
      db.reset();

      // A second of frames over a sidebar where nothing moved. The filter's
      // answer is a memoised provider, so re-reading it is what a rebuilding
      // widget does and it must cost nothing.
      for (var frame = 0; frame < 180; frame++) {
        result.container.read(explorerSectionLayoutProvider);
      }
      await tester.pump();

      // ignore: avoid_print
      print('SECTION-FILTER idle statements=${db.count}');
      expect(
        db.statements,
        isEmpty,
        reason:
            'a filter that re-queried per rebuild is the whole regression '
            'this file exists to catch: ${db.statements}',
      );
    });
  });
}
