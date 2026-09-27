import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/domain/explorer_section.dart';
import 'package:karmashala/src/features/explorer/application/explorer_view_mode.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_projects/karmashala_projects.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **What a section actually holds, and what it refuses to go and find out.**
///
/// The cost claim lives in `explorer_sections_cost_test.dart`; this file is
/// about the consequence of that claim being true. A section reports what the
/// app has already measured — so a branch a card asked git about is a branch a
/// glob can match, and a checkout nobody has looked at is one no glob matches.
/// That second half is a *feature* being asserted, not a limitation being
/// tolerated: the alternative was a second `gh`-and-git sweep over every row in
/// the workspace.
void main() {
  const repoPath = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo\app',
  );

  // The server the last [seed] filled; every container built after it reads it.
  late FakeDataServer server;

  TestMachine seed({int failed = 1, int running = 1}) {
    final db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    seedDefaultSections(server);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(
      project(id: 'p1', name: 'Demo', path: r'C:\src\demo'),
    );
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    for (var i = 0; i < failed; i++) {
      db.server.sessionRows.insert(
        session(id: 'f$i', title: 'Failed $i', status: SessionStatus.failed),
      );
    }
    for (var i = 0; i < running; i++) {
      db.server.sessionRows.insert(
        session(id: 'r$i', title: 'Running $i', status: SessionStatus.running),
      );
    }
    return db;
  }

  /// Git answering `status --porcelain=v2 --branch` with one branch name, and
  /// nothing else.
  FakeCommandRunner gitOn(String branch) => FakeCommandRunner(
    responder: (request) {
      final verb = request.arguments.skip(2).toList();
      if (verb.isNotEmpty && verb.first == 'status') {
        return CommandResult(
          exitCode: 0,
          stdout: verb.contains('--branch') ? porcelainV2(branch: branch) : '',
          stderr: '',
        );
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    },
  );

  Future<ProviderContainer> mount(TestMachine db, FakeCommandRunner git) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          server.gitWork.serve(FakeCommandRunnerFactory(fallback: git)),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(explorerSectionAssignmentProvider, (_, _) {});
    return container;
  }

  List<String> idsIn(ProviderContainer container, String sectionId) => [
    for (final facts in container.read(
      explorerSectionMembersProvider(sectionId),
    ))
      facts.id,
  ];

  group('a rule section', () {
    test('files a session its own row already condemns', () async {
      final db = seed(failed: 2);
      final container = await mount(db, FakeCommandRunner());
      await container.pump();

      expect(idsIn(container, 'section-ended-in-failure'), ['f0', 'f1']);
      expect(idsIn(container, 'section-checks-failing'), isEmpty);
    });

    test('files an agent the ambient waiting list says is stuck', () async {
      final db = seed();
      final container = await mount(db, FakeCommandRunner());
      await container.pump();
      expect(idsIn(container, 'section-awaiting-input'), isEmpty);

      container.read(sessionAttentionProvider.notifier).set(const [
        SessionAttention(
          session: WatchedSession(
            key: AgentSessionKey('claudeCode', 'ext-r0'),
            label: 'Running 0',
            openId: 'r0',
            imported: false,
          ),
          kind: AttentionKind.needsInput,
        ),
      ]);
      await container.pump();

      expect(idsIn(container, 'section-awaiting-input'), ['r0']);
    });

    test('matches a branch something else already measured', () async {
      final db = seed();
      final git = gitOn('release/1.4');
      final container = await mount(db, git);
      final sections = container.read(explorerSectionsProvider.notifier);
      final releases = sections.add(
        name: 'Releases',
        rule: BranchGlobRule('release/*'),
      );
      // Opened, because the delivery heartbeat below is what a section with
      // rows *on screen* rides — see [explorerSectionFactsProvider]. A folded
      // section is refreshed by `deliveryAttentionProvider` instead, which is
      // what every strip reading in the app actually writes to.
      sections.setCollapsed(releases.id, false);
      await container.pump();

      // Nothing has looked at this checkout, so nothing knows its branch — and
      // the section says so by being empty rather than by going to find out.
      // This is the bargain, asserted: the sidebar reports, it does not probe.
      expect(idsIn(container, releases.id), isEmpty);
      expect(
        git.requests,
        isEmpty,
        reason: 'a section must never be the thing that starts git',
      );

      // Now a row asks, the way a drawn session card does, and the app's own
      // delivery heartbeat comes round — which is the only thing a section
      // waits for.
      container.listen(
        checkoutDeliveryProvider(const Checkout(repoPath)),
        (_, _) {},
      );
      await container.pump();
      final measured = git.requests.length;
      expect(measured, greaterThan(0), reason: 'the card really did ask');
      container.read(deliveryPollProvider.notifier).state++;
      await container.pump();

      // Only `r0`: both sessions are on `release/1.4`, but `f0` also failed
      // and "Ended in failure" is seeded above this section, so it took it.
      // That is position-as-priority working, not the glob missing a row.
      expect(idsIn(container, releases.id), ['r0']);
      expect(idsIn(container, 'section-ended-in-failure'), ['f0']);
      expect(
        git.requests.length,
        measured,
        reason: 'reading the answer a card paid for must not pay for it again',
      );
    });
  });

  group('when two sections want the same row', () {
    test('a pin takes it out of the rule section below', () async {
      final db = seed();
      final container = await mount(db, FakeCommandRunner());
      await container.pump();
      expect(idsIn(container, 'section-ended-in-failure'), ['f0']);

      container
          .read(settingsControllerProvider.notifier)
          .togglePinnedSession('f0');
      await container.pump();

      expect(idsIn(container, kPinnedSectionId), ['f0']);
      expect(
        idsIn(container, 'section-ended-in-failure'),
        isEmpty,
        reason:
            'an explicit act outranks a rule, or "pin this" stops meaning '
            'anything',
      );
    });

    test('dragging a section above another moves the rows with it', () async {
      final db = seed();
      final container = await mount(db, gitOn('release/1.4'));
      final controller = container.read(explorerSectionsProvider.notifier);
      final releases = controller.add(
        name: 'Releases',
        rule: BranchGlobRule('release/*'),
      );
      controller.setCollapsed(releases.id, false);
      container.listen(
        checkoutDeliveryProvider(const Checkout(repoPath)),
        (_, _) {},
      );
      await container.pump();
      container.read(deliveryPollProvider.notifier).state++;
      await container.pump();

      // "Ended in failure" is seeded above the new section, so it claims f0.
      expect(idsIn(container, 'section-ended-in-failure'), ['f0']);
      expect(idsIn(container, releases.id), ['r0']);

      // Dragged to the top of the editable range — under Pinned, which cannot
      // be displaced.
      final index = container
          .read(explorerSectionsProvider)
          .indexWhere((s) => s.id == releases.id);
      controller.move(index, 0);
      await container.pump();

      expect(
        container.read(explorerSectionsProvider).first.isPinned,
        isTrue,
        reason: 'Pinned is the top of the priority order by definition',
      );
      expect(idsIn(container, releases.id), ['f0', 'r0']);
      expect(idsIn(container, 'section-ended-in-failure'), isEmpty);
    });

    test('a hand-filled group beats a rule that is above it', () async {
      final db = seed();
      final container = await mount(db, FakeCommandRunner());
      final controller = container.read(explorerSectionsProvider.notifier);
      final mine = controller.add(name: 'Mine', rule: const ManualRule());
      controller.addMember(mine.id, 'f0');
      await container.pump();

      expect(idsIn(container, mine.id), ['f0']);
      expect(idsIn(container, 'section-ended-in-failure'), isEmpty);

      controller.removeMember(mine.id, 'f0');
      await container.pump();
      expect(idsIn(container, 'section-ended-in-failure'), ['f0']);
    });
  });

  group('the sidebar', () {
    /// [hideEmpty] is `Settings.hideEmptySections`, and it is a parameter
    /// rather than the default because the two halves of this group need
    /// opposite answers: what a section *says* is only visible with the filter
    /// off, and what the filter *does* is only visible with it on.
    Future<ProviderContainer> pump(
      WidgetTester tester,
      TestMachine db, {
      bool hideEmpty = true,
    }) async {
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            server.gitWork.serve(FakeCommandRunnerFactory(fallback: FakeCommandRunner())),
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
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('opens a section and says which project each row is in', (
      tester,
    ) async {
      final db = seed();
      await pump(tester, db);

      // Folded shut, so the failed session is nowhere on screen even though
      // its project is right below.
      expect(find.text('Failed 0'), findsNothing);

      await tester.tap(find.text('Ended in failure'));
      await tester.pumpAndSettle();

      expect(find.text('Failed 0'), findsOneWidget);
      expect(
        find.text('Running 0'),
        findsNothing,
        reason: 'the rule is the whole point',
      );
      // A section crosses projects, so a row in one has to say where it is —
      // the tree never has to, because its header already did.
      expect(find.textContaining('Demo/app'), findsWidgets);
    });

    testWidgets('an open, empty section explains itself', (tester) async {
      final db = seed(failed: 0);
      await pump(tester, db, hideEmpty: false);

      await tester.tap(find.text('Checks failing'));
      await tester.pumpAndSettle();

      // Not a blank space. "No failing checks" and "nobody has asked about
      // these checkouts yet" are different situations, and this app is only
      // ever in the second one until a Delivery strip has been opened.
      expect(find.textContaining('Delivery strip'), findsOneWidget);
    });

    testWidgets('a section folds back shut and takes its rows with it', (
      tester,
    ) async {
      final db = seed();
      await pump(tester, db);

      await tester.tap(find.text('Ended in failure'));
      await tester.pumpAndSettle();
      expect(find.text('Failed 0'), findsOneWidget);

      await tester.tap(find.text('Ended in failure'));
      await tester.pumpAndSettle();
      expect(find.text('Failed 0'), findsNothing);
    });
  });

  /// **What the sidebar does with a section that holds nothing.**
  ///
  /// The complaint this answers, in the owner's words: three collapsed rows
  /// saying "Checks failing", "Awaiting input" and "Ended in failure" above the
  /// tree, each costing a full row whether or not it had anything in it.
  group('the empty filter', () {
    Future<ProviderContainer> pump(WidgetTester tester, TestMachine db) async {
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            server.gitWork.serve(FakeCommandRunnerFactory(fallback: FakeCommandRunner())),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
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
      return container;
    }

    testWidgets('folds away the sections holding nothing, and only those', (
      tester,
    ) async {
      final db = seed();
      await pump(tester, db);

      // One failed session, so exactly one of the four seeded sections has
      // anything to say. The other three cost nothing at all.
      expect(find.text('Ended in failure'), findsOneWidget);
      expect(find.text('Checks failing'), findsNothing);
      expect(find.text('Awaiting input'), findsNothing);
      expect(find.text('Pinned'), findsNothing);
    });

    testWidgets('says how many it is holding back, and gives them back', (
      tester,
    ) async {
      final db = seed();
      final container = await pump(tester, db);

      // The funnel is the whole of the feature's discoverability: a section
      // nobody can see is a section nobody can learn about, so it admits to
      // the three it is hiding — before it is even opened — rather than
      // leaving the sidebar looking as though sections were never there.
      const tooltip = 'Filter sessions \u00b7 3 empty sections hidden';
      expect(find.byTooltip(tooltip), findsOneWidget);

      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      // And the row that gives them back names the same count.
      await tester.tap(find.text('Show 3 empty sections'));
      await tester.pumpAndSettle();

      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Checks failing'), findsOneWidget);
      expect(find.text('Ended in failure'), findsOneWidget);
      expect(
        container.read(settingsControllerProvider).hideEmptySections,
        isFalse,
        reason: 'the choice is a setting, so it survives a restart',
      );
    });

    testWidgets('a section comes back the moment something lands in it', (
      tester,
    ) async {
      final db = seed();
      final container = await pump(tester, db);
      expect(find.text('Pinned'), findsNothing);

      container
          .read(settingsControllerProvider.notifier)
          .togglePinnedSession('r0');
      await tester.pumpAndSettle();

      expect(
        find.text('Pinned'),
        findsOneWidget,
        reason: 'hidden is a filter over live membership, not a deletion',
      );
    });

    testWidgets('an open section stays open even with nothing in it', (
      tester,
    ) async {
      final db = seed(failed: 0);
      final container = await pump(tester, db);

      // Opened by hand — the user is looking at it, and the sentence under it
      // is the answer they opened it for. Pulling it out from under them mid
      // -glance would answer nothing.
      container
          .read(explorerSectionsProvider.notifier)
          .setCollapsed('section-checks-failing', false);
      await tester.pumpAndSettle();

      expect(find.text('Checks failing'), findsOneWidget);
      expect(find.textContaining('Delivery strip'), findsOneWidget);
    });
  });
}

/// The four sections a new workspace starts with — seeded by the server's
/// own schema, which the fake does not have.
void seedDefaultSections(FakeDataServer server) {
  for (final (id, name, kind, position) in const [
    ('section-pinned', 'Pinned', 'pinned', 0),
    ('section-checks-failing', 'Checks failing', 'checksFailing', 1),
    ('section-awaiting-input', 'Awaiting input', 'awaitingInput', 2),
    ('section-ended-in-failure', 'Ended in failure', 'endedInFailure', 3),
  ]) {
    server.sectionRows.put(
      StoredSection(id: id, name: name, kind: kind, position: position),
    );
  }
}
