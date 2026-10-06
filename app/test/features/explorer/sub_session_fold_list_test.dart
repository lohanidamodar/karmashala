import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// A parent's sub-sessions fold beneath it — "3 sub-sessions · 1 running" —
/// always folded by default, with the live ones still in
/// sight, and the choice kept per device.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  void insert(
    String id, {
    SessionStatus status = SessionStatus.completed,
    String? parent,
    int minutes = 0,
  }) => db.server.sessionRows.insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Chat $id',
      useWorktree: false,
      status: status,
      createdAt: testTime.add(Duration(minutes: minutes)),
      parentSessionId: parent,
    ),
  );

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows.insert(project(id: 'p1', name: 'Alpha'));
    server.repositoryRows.insert(repository(id: 'r1', projectId: 'p1'));
    insert('lead');
    insert('c1', parent: 'lead', minutes: 1);
    insert('c2', parent: 'lead', minutes: 2);
    insert('busy', parent: 'lead', minutes: 3, status: SessionStatus.running);
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Size size,
    Widget body,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db, data: await server.override()),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390x844', Size(390, 844)),
  ]) {
    testWidgets('$name: the Sessions list folds a parent\'s ended '
        'sub-sessions under it and keeps the live one in sight', (
      tester,
    ) async {
      server.attention.statusOf(
        'busy',
        AgentActivityStatus.working,
        sessionId: 'cli-busy',
        label: 'busy',
      );
      final c = await pump(tester, size, const AgentsPage());
      expect(find.text('Chat busy'), findsOneWidget, reason: 'working');
      await tester.tap(find.text('ENDED'));
      await tester.pumpAndSettle();

      expect(find.text('Chat lead'), findsOneWidget);
      expect(find.text('3 sub-sessions · 1 running'), findsOneWidget);
      expect(find.text('Chat c1'), findsNothing, reason: 'the parent ended');

      await tester.tap(find.text('3 sub-sessions · 1 running'));
      await tester.pumpAndSettle();
      expect(find.text('Chat c1'), findsOneWidget);
      expect(find.text('Chat c2'), findsOneWidget);
      expect(c.read(sessionListPrefsProvider).folds, {'lead': false});
      expect(
        tester.getTopLeft(find.text('Chat c1')).dx,
        greaterThan(tester.getTopLeft(find.text('Chat lead')).dx),
        reason: 'beneath it',
      );
      // `busy` works on hook evidence, which arms the quiet timer; leaving
      // the page is what cancels it.
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }

  testWidgets('the project tree folds them the same way', (tester) async {
    final c = await pump(
      tester,
      const Size(1440, 900),
      const ExplorerPanel(terminals: false),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('Chat lead'), findsOneWidget);
    expect(find.text('3 sub-sessions · 1 running'), findsOneWidget);
    expect(find.text('Chat busy'), findsOneWidget, reason: 'live: in sight');
    expect(find.text('Chat c1'), findsNothing);

    await tester.tap(find.text('3 sub-sessions · 1 running'));
    await tester.pumpAndSettle();
    expect(find.text('Chat c1'), findsOneWidget);
    expect(c.read(sessionListPrefsProvider).folds, {'lead': false});

    await tester.tap(find.text('3 sub-sessions · 1 running'));
    await tester.pumpAndSettle();
    expect(find.text('Chat c1'), findsNothing);
  });

  // The owner's orchestrator: a parent still working, 40 finished children
  // and one running, which started before most of them.
  void family() {
    insert('boss', status: SessionStatus.running, minutes: 10);
    insert('live', parent: 'boss', minutes: 11, status: SessionStatus.running);
    for (var i = 1; i <= 40; i++) {
      insert('e$i', parent: 'boss', minutes: 11 + i);
    }
  }

  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390x844', Size(390, 844)),
  ]) {
    testWidgets('$name: a working parent\'s 40 finished sub-sessions start '
        'folded in the tree, its running one in sight', (tester) async {
      family();
      final c = await pump(tester, size, const ExplorerPanel(terminals: false));
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      expect(find.text('Chat boss'), findsOneWidget);
      expect(find.text('41 sub-sessions · 1 running'), findsOneWidget);
      expect(find.text('Chat live'), findsOneWidget, reason: 'running');
      expect(find.text('Chat e40'), findsNothing);
      expect(find.text('Chat e1'), findsNothing);

      await tester.tap(find.text('41 sub-sessions · 1 running'));
      await tester.pumpAndSettle();
      expect(c.read(sessionListPrefsProvider).folds, {'boss': false});
      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(y('Chat live'), lessThan(y('Chat e40')), reason: 'running first');
      expect(y('Chat e40'), lessThan(y('Chat e39')), reason: 'newest first');
    });

    testWidgets('$name: the Sessions list folds a working parent\'s 40 '
        'finished sub-sessions, newest first when opened', (tester) async {
      family();
      for (final id in ['boss', 'live']) {
        server.attention.statusOf(
          id,
          AgentActivityStatus.working,
          sessionId: 'cli-$id',
          label: id,
        );
      }
      final c = await pump(tester, size, const AgentsPage());
      expect(find.text('Chat boss'), findsOneWidget);
      expect(find.text('Chat live'), findsOneWidget, reason: 'working');
      expect(find.text('41 sub-sessions · 1 running'), findsOneWidget);
      expect(find.text('Chat e40'), findsNothing);

      await tester.tap(find.text('41 sub-sessions · 1 running'));
      await tester.pumpAndSettle();
      expect(c.read(sessionListPrefsProvider).folds, {'boss': false});
      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(y('Chat boss'), lessThan(y('Chat e40')));
      expect(y('Chat e40'), lessThan(y('Chat e39')), reason: 'newest first');
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }

  testWidgets('a remembered open choice wins over the fold', (tester) async {
    family();
    final c = await pump(
      tester,
      const Size(1440, 900),
      const ExplorerPanel(terminals: false),
    );
    c.read(sessionListPrefsProvider.notifier).setFolded('boss', false);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Chat e40'), findsOneWidget);
  });
}
