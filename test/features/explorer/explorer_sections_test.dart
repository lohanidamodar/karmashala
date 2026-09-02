import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/explorer/application/checkout.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/domain/explorer_section.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
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

  AppDatabase seed({int failed = 1, int running = 1}) {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(
      db,
    ).insert(project(id: 'p1', name: 'Demo', path: r'C:\src\demo'));
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    for (var i = 0; i < failed; i++) {
      SessionDao(db).insert(
        session(id: 'f$i', title: 'Failed $i', status: SessionStatus.failed),
      );
    }
    for (var i = 0; i < running; i++) {
      SessionDao(db).insert(
        session(id: 'r$i', title: 'Running $i', status: SessionStatus.running),
      );
    }
    return db;
  }

  /// Git answering `status --porcelain=v1 --branch` with one branch name, and
  /// nothing else.
  FakeCommandRunner gitOn(String branch) => FakeCommandRunner(
    responder: (request) {
      final verb = request.arguments.skip(2).toList();
      if (verb.isNotEmpty && verb.first == 'status') {
        return CommandResult(
          exitCode: 0,
          stdout: verb.contains('--branch') ? '## $branch\n' : '',
          stderr: '',
        );
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    },
  );

  ProviderContainer mount(AppDatabase db, FakeCommandRunner git) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
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
      addTearDown(db.close);
      final container = mount(db, FakeCommandRunner());
      await container.pump();

      expect(idsIn(container, 'section-ended-in-failure'), ['f0', 'f1']);
      expect(idsIn(container, 'section-checks-failing'), isEmpty);
    });

    test('files an agent the ambient waiting list says is stuck', () async {
      final db = seed();
      addTearDown(db.close);
      final container = mount(db, FakeCommandRunner());
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
      addTearDown(db.close);
      final git = gitOn('release/1.4');
      final container = mount(db, git);
      final sections = container.read(explorerSectionsProvider.notifier);
      final releases = sections.add(
        name: 'Releases',
        rule: BranchGlobRule('release/*'),
      );
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
      addTearDown(db.close);
      final container = mount(db, FakeCommandRunner());
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
      addTearDown(db.close);
      final container = mount(db, gitOn('release/1.4'));
      final controller = container.read(explorerSectionsProvider.notifier);
      final releases = controller.add(
        name: 'Releases',
        rule: BranchGlobRule('release/*'),
      );
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
      addTearDown(db.close);
      final container = mount(db, FakeCommandRunner());
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
    Future<void> pump(WidgetTester tester, AppDatabase db) async {
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
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
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('opens a section and says which project each row is in', (
      tester,
    ) async {
      final db = seed();
      addTearDown(db.close);
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
      addTearDown(db.close);
      await pump(tester, db);

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
      addTearDown(db.close);
      await pump(tester, db);

      await tester.tap(find.text('Ended in failure'));
      await tester.pumpAndSettle();
      expect(find.text('Failed 0'), findsOneWidget);

      await tester.tap(find.text('Ended in failure'));
      await tester.pumpAndSettle();
      expect(find.text('Failed 0'), findsNothing);
    });
  });
}
