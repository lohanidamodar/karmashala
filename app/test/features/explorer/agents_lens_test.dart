import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_view_mode.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';

/// **The Agents entry and the page it opens**, drawn: the count appears only
/// above zero, the page groups by state in its order with its folds, and
/// leaving it puts the tree back.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late AgentHookReceiver receiver;
  late SessionStatusRegistry registry;
  late List<WatchedSession> watched;

  WatchedSession watch(String row) => WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'cli-$row'),
    label: row,
    openId: row,
    imported: false,
  );

  void insert(
    String id, {
    SessionStatus status = SessionStatus.running,
    String? worktree,
    Duration age = Duration.zero,
  }) => mirroredServer(db).sessionRows.insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Chat $id',
      useWorktree: worktree != null,
      worktree: worktree == null
          ? null
          : EnvironmentPath(environmentId: 'windows', path: worktree),
      status: status,
      createdAt: testTime.subtract(age),
    ),
  );

  setUp(() {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    AgentInstallationDao(db).insert(agentInstallation());
    server.projectRows.insert(
      project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'),
    );
    server.repositoryRows.insert(
      repository(
        id: 'r1',
        projectId: 'p1',
        name: 'alpha',
        path: r'C:\src\alpha',
      ),
    );
    final clock = FixedClock(testTime);
    final reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    watched = [];
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    );
  });
  tearDown(() {
    registry.dispose();
    db.close();
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        sessionStatusRegistryProvider.overrideWithValue(registry),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Row(
              children: [
                SizedBox(width: 360, child: ExplorerPanel()),
                Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  void hook(String row, String event, {String extra = ''}) {
    receiver.handle(
      agentId: AgentIds.claudeCode,
      event: event,
      body: '{"session_id":"cli-$row"$extra}',
    );
    registry.hookReported(AgentSessionKey(AgentIds.claudeCode, 'cli-$row'));
  }

  void fileWaiting(ProviderContainer c, List<String> ids) => c
      .read(attentionInboxProvider.notifier)
      .apply(
        InboxUpdate(
          waiting: [
            for (final id in ids)
              SessionAttention(
                session: watch(id),
                kind: AttentionKind.needsInput,
              ),
          ],
          watched: {for (final s in watched) s.key},
        ),
      );

  Finder pill() => find.byKey(const ValueKey('agents-needs-you-pill'));

  testWidgets('the count is drawn only while something is waiting', (
    tester,
  ) async {
    insert('s1');
    watched = [watch('s1')];
    await registry.cycle();
    final c = await pump(tester);

    expect(find.text('Agents'), findsOneWidget);
    expect(pill(), findsNothing, reason: 'no dead chrome at zero');
    expect(find.bySemanticsLabel('Agents'), findsOneWidget);

    fileWaiting(c, ['s1']);
    await tester.pump();
    expect(pill(), findsOneWidget);
    expect(
      find.descendant(of: pill(), matching: find.text('1')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Agents, 1 session waiting on you'),
      findsOneWidget,
    );

    fileWaiting(c, const []);
    await tester.pump();
    expect(pill(), findsNothing, reason: 'answered, it goes again');
  });

  testWidgets('the page groups every session by state, in order, with its '
      'folds', (tester) async {
    insert('waiting');
    insert('busy');
    for (var i = 0; i < 10; i++) {
      insert(
        'ready$i',
        status: SessionStatus.idle,
        age: Duration(minutes: i),
      );
    }
    insert('done', status: SessionStatus.completed);
    watched = [watch('waiting'), watch('busy')];
    await registry.cycle();
    hook('busy', 'PreToolUse');
    final c = await pump(tester);
    fileWaiting(c, ['waiting']);

    await tester.tap(find.text('Agents'));
    await tester.pumpAndSettle();

    expect(c.read(explorerLensProvider), ExplorerLens.agents);
    expect(find.byType(AgentsPage), findsOneWidget);
    expect(find.byType(ExplorerTreeView).hitTestable(), findsNothing);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(
      find.text('FAILED'),
      findsNothing,
      reason: 'an empty group is not drawn',
    );
    expect(top('NEEDS YOU'), lessThan(top('WORKING')));
    expect(top('WORKING'), lessThan(top('READY')));
    expect(top('READY'), lessThan(top('ENDED')));
    expect(top('Chat waiting'), lessThan(top('WORKING')));
    expect(top('Chat busy'), lessThan(top('READY')));

    // Ready: eight, then the rest behind a line that says how many.
    for (var i = 0; i < 8; i++) {
      expect(find.text('Chat ready$i'), findsOneWidget);
    }
    expect(find.text('Chat ready8'), findsNothing);
    expect(find.text('Show 2 more'), findsOneWidget);
    await tester.tap(find.text('Show 2 more'));
    await tester.pumpAndSettle();
    expect(find.text('Chat ready9'), findsOneWidget);
    expect(find.text('Show fewer'), findsOneWidget);

    // Ended: folded until its header is opened.
    expect(find.text('Chat done'), findsNothing);
    await tester.tap(find.text('ENDED'));
    await tester.pumpAndSettle();
    expect(find.text('Chat done'), findsOneWidget);

    // `busy` is working on hook evidence, so the page armed the one timer for
    // when it would turn quiet; leaving the page is what cancels it.
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('a row names its project, and its folder only when it is not '
      'the project again', (tester) async {
    insert('root');
    insert('wt', worktree: r'C:\wt\feature-x');
    final c = await pump(tester);
    c.read(explorerLensProvider.notifier).toggle(ExplorerLens.agents);
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget, reason: 'the root session');
    expect(find.text('Alpha  ·  feature-x'), findsOneWidget);
    expect(find.textContaining('alpha  ·'), findsNothing);
  });

  testWidgets('the entry is reached and pressed from the keyboard, and '
      'pressing it again goes back to the tree', (tester) async {
    insert('s1');
    final c = await pump(tester);
    final node = Focus.of(tester.element(find.text('Agents')));
    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(c.read(explorerLensProvider), ExplorerLens.agents);
    expect(find.byType(AgentsPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(c.read(explorerLensProvider), ExplorerLens.projects);
    expect(find.byType(AgentsPage), findsNothing);
    expect(find.text('Alpha').hitTestable(), findsOneWidget);
  });
}
