import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/shell_area.dart';
import 'package:karmashala/src/app/shell/shell_sidebar.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/explorer_view_mode.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/notifications/application/focus_mode.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

class _Live extends LiveAgentStatuses {
  @override
  Map<String, AgentActivityStatus> build() => const {
    'w': AgentActivityStatus.working,
    'w-ask': AgentActivityStatus.awaitingApproval,
    'n': AgentActivityStatus.awaitingApproval,
  };
}

/// Every list drops a working session behind one "N working · Show" line while
/// "Hide while working" is on, and Show turns it off — desktop and phone.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  void insert(
    String id, {
    SessionStatus status = SessionStatus.running,
    String? parent,
  }) => db.server.sessionRows.insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Chat $id',
      useWorktree: false,
      status: status,
      createdAt: testTime,
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
    insert('w');
    insert('w-done', status: SessionStatus.completed, parent: 'w');
    insert('w-ask', parent: 'w');
    insert('n');
    insert('r', status: SessionStatus.idle);
    server.sectionRows.put(
      const StoredSection(
        id: 'mine',
        name: 'Mine',
        kind: StoredSection.manualKind,
        position: 0,
        collapsed: false,
        members: {'w', 'r'},
      ),
    );
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Size size, {
    Widget body = const AgentsPage(),
    bool hide = true,
  }) async {
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
        liveAgentStatusesProvider.overrideWith(_Live.new),
        needsYouProvider.overrideWithValue(const {
          'w-ask': NeedsYouSource(label: 'w-ask', imported: false),
          'n': NeedsYouSource(label: 'n', imported: false),
        }),
      ],
    );
    addTearDown(container.dispose);
    if (hide) {
      container.read(sessionListPrefsProvider.notifier).setHideWorking(true);
    }
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

  Future<void> show(WidgetTester tester, ProviderContainer c) async {
    await tester.tap(find.text('1 working · Show'));
    await tester.pumpAndSettle();
    expect(c.read(hideWorkingSessionsProvider), isFalse);
    expect(find.text('1 working · Show'), findsNothing);
    expect(find.text('Chat w'), findsOneWidget);
  }

  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390x844', Size(390, 844)),
  ]) {
    testWidgets('$name: the Agents page has one line where Working was', (
      tester,
    ) async {
      final c = await pump(tester, size);
      expect(find.text('Chat w'), findsNothing);
      expect(find.text('WORKING'), findsNothing);
      expect(find.text('Chat w-ask'), findsOneWidget);
      expect(find.text('Chat n'), findsOneWidget);
      expect(find.text('Chat r'), findsOneWidget);
      expect(find.text('1 working · Show'), findsOneWidget);
      await show(tester, c);
    });

    testWidgets('$name: the project tree has the line under the project', (
      tester,
    ) async {
      final c = await pump(
        tester,
        size,
        body: const ExplorerPanel(terminals: false),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('Chat w'), findsNothing);
      expect(find.text('Chat w-done'), findsNothing);
      expect(find.text('Chat w-ask'), findsOneWidget);
      expect(find.text('Chat r'), findsOneWidget);
      expect(find.text('1 working · Show'), findsOneWidget);
      await show(tester, c);
    });

    testWidgets('$name: a section has the line where its member was', (
      tester,
    ) async {
      final c = await pump(
        tester,
        size,
        body: const ExplorerPanel(terminals: false),
      );
      c.read(explorerShowingViewsProvider.notifier).toggle();
      await tester.pumpAndSettle();
      expect(find.text('Chat w'), findsNothing);
      expect(find.text('Chat r'), findsOneWidget);
      expect(find.text('1 working · Show'), findsOneWidget);
      await show(tester, c);
    });
  }

  testWidgets('off by default: no line, and the Working group is drawn', (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900), hide: false);
    expect(find.text('Chat w'), findsOneWidget);
    expect(find.text(AgentState.working.label.toUpperCase()), findsOneWidget);
    expect(find.textContaining('working · Show'), findsNothing);
  });

  testWidgets('the Explorer filter menu has the switch beside Show archived', (
    tester,
  ) async {
    final c = await pump(
      tester,
      const Size(1440, 900),
      body: const ExplorerPanel(terminals: false),
      hide: false,
    );
    await tester.tap(find.byTooltip('Filter sessions'));
    await tester.pumpAndSettle();
    expect(find.text('Show archived'), findsOneWidget);
    await tester.tap(find.text('Hide while working'));
    await tester.pumpAndSettle();
    expect(c.read(hideWorkingSessionsProvider), isTrue);
  });

  testWidgets('the Sessions list header has the switch', (tester) async {
    final c = await pump(
      tester,
      const Size(1440, 900),
      body: const ShellSidebar(),
      hide: false,
    );
    c.read(shellAreaProvider.notifier).select(ShellArea.sessions);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hide while working'));
    await tester.pumpAndSettle();
    expect(c.read(hideWorkingSessionsProvider), isTrue);
    expect(find.byTooltip('Show working sessions'), findsOneWidget);
  });

  testWidgets('quick open turns it on and off', (tester) async {
    final c = await pump(
      tester,
      const Size(1440, 900),
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => QuickOpen.show(context),
          child: const Text('open'),
        ),
      ),
      hide: false,
    );
    Future<void> run(String title) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'working');
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    await run('Hide sessions while they work');
    expect(c.read(hideWorkingSessionsProvider), isTrue);
    await run('Show working sessions');
    expect(c.read(hideWorkingSessionsProvider), isFalse);
  });

  testWidgets('quick open turns Focus on and off', (tester) async {
    final c = await pump(
      tester,
      const Size(1440, 900),
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => QuickOpen.show(context),
          child: const Text('open'),
        ),
      ),
      hide: false,
    );
    Future<void> run(String title) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'focus');
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    await run('Turn on Focus');
    expect(c.read(focusModeProvider), isTrue);
    expect(c.read(hideWorkingSessionsProvider), isTrue);
    expect(
      c.read(notificationSettingsControllerProvider).level,
      NotifyLevel.whenNeeded,
    );
    await run('Turn off Focus');
    expect(c.read(focusModeProvider), isFalse);
    expect(c.read(hideWorkingSessionsProvider), isFalse);
    expect(
      c.read(notificationSettingsControllerProvider).level,
      NotifyLevel.everything,
    );
  });
}
