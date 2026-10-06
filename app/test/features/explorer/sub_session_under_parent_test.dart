import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/sub_sessions_fold_row.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:agent_cli/descriptors.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// A sub-session always sits under its parent, never in a status group of its
/// own, and the fold line counts only the rows beneath it. The owner's case: a
/// parent in Ready, two children running, forty archived.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  void insert(
    String id, {
    SessionStatus status = SessionStatus.completed,
    String? parent,
    int minutes = 0,
    bool archived = false,
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
      archivedAt: archived ? testTime : null,
    ),
  );

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows.insert(project(id: 'p1', name: 'Alpha'));
    server.repositoryRows.insert(repository(id: 'r1', projectId: 'p1'));
    insert('lead', status: SessionStatus.idle);
    insert('w1', parent: 'lead', minutes: 1, status: SessionStatus.running);
    insert('w2', parent: 'lead', minutes: 2, status: SessionStatus.running);
    for (var i = 1; i <= 40; i++) {
      insert('done$i', parent: 'lead', minutes: 2 + i, archived: true);
    }
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

  /// The fold line, its count matching the rows beneath it, and no chevron:
  /// both children are already in sight, so there is nothing to open.
  void expectFoldMatchesRows(WidgetTester tester, ProviderContainer c) {
    expect(find.text('2 sub-sessions · 2 running'), findsOneWidget);
    final badge = find.byKey(const ValueKey('running-below:lead'));
    expect(
      find.descendant(of: badge, matching: find.text('2 running')),
      findsOneWidget,
      reason: 'the parent wears its children\'s count',
    );
    expect(
      tester.getTopLeft(badge).dy,
      lessThan(tester.getTopLeft(find.text('2 sub-sessions · 2 running')).dy),
      reason: 'on the parent\'s own row',
    );
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    double x(String text) => tester.getTopLeft(find.text(text)).dx;
    for (final child in ['Chat w1', 'Chat w2']) {
      expect(find.text(child), findsOneWidget, reason: 'listed once');
      expect(y(child), greaterThan(y('2 sub-sessions · 2 running')));
      expect(x(child), greaterThan(x('Chat lead')), reason: 'beneath it');
    }
    expect(find.textContaining('Chat done'), findsNothing);
    final fold = find.byType(SubSessionsFoldRow);
    for (final caret in [AppIcons.caretRight, AppIcons.caretDown]) {
      expect(
        find.descendant(of: fold, matching: find.byIcon(caret)),
        findsNothing,
      );
    }
    expect(fold, findsOneWidget);
    expect(c.read(sessionListPrefsProvider).folds, isEmpty);
  }

  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390x844', Size(390, 844)),
  ]) {
    testWidgets('$name: the Sessions list keeps working children under their '
        'Ready parent, out of the status groups', (tester) async {
      for (final id in ['w1', 'w2']) {
        server.attention.statusOf(
          id,
          AgentActivityStatus.working,
          sessionId: 'cli-$id',
          label: id,
        );
      }
      final c = await pump(tester, size, const AgentsPage());

      expect(find.text('READY'), findsOneWidget);
      expect(find.text('WORKING'), findsNothing, reason: 'no child group');
      expectFoldMatchesRows(tester, c);

      await tester.tap(find.text('2 sub-sessions · 2 running'));
      await tester.pumpAndSettle();
      expectFoldMatchesRows(tester, c);
      // `w1`/`w2` work on hook evidence, which arms the quiet timer; leaving
      // the page is what cancels it.
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });

    testWidgets('$name: the project tree shows the same rows and count', (
      tester,
    ) async {
      final c = await pump(tester, size, const ExplorerPanel(terminals: false));
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();

      expectFoldMatchesRows(tester, c);
    });
  }

  testWidgets('a running child of an ended parent is still in sight while '
      'the Ended group is folded', (tester) async {
    db.server.sessionRows.updateStatus('lead', SessionStatus.completed);
    server.attention.statusOf(
      'w1',
      AgentActivityStatus.working,
      sessionId: 'cli-w1',
      label: 'w1',
    );
    final c = await pump(tester, const Size(1440, 900), const AgentsPage());

    expect(find.text('Chat lead'), findsOneWidget);
    expect(find.text('Chat w1'), findsOneWidget);
    expect(find.text('WORKING'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
