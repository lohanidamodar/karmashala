import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_view_mode.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/session_selection_bar.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The Agents entry and the page it opens**, drawn: the count appears only
/// above zero, the page groups by state in its order with its folds, and
/// leaving it puts the tree back.
void main() {
  late TestMachine db;
  late FakeDataServer server;
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
  }) => db.server.sessionRows.insert(
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
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
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
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        await server.override(),
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

  /// The server's word: [row]'s agent is in a turn, by its hook.
  void working(String row) => server.attention.statusOf(
    row,
    AgentActivityStatus.working,
    sessionId: 'cli-$row',
    label: row,
  );

  /// The server's inbox and waiting list: [ids] need approval, nothing else.
  void fileWaiting(ProviderContainer c, List<String> ids) =>
      server.attention.setInbox(
        AttentionInbox(
          items: [
            for (final id in ids)
              InboxItem(
                session: watch(id),
                kind: InboxItemKind.needsApproval,
                at: testTime,
              ),
          ],
        ),
        waiting: [
          for (final id in ids)
            SessionAttention(
              session: watch(id),
              kind: AttentionKind.needsInput,
            ),
        ],
      );

  Finder pill() => find.byKey(const ValueKey('agents-needs-you-pill'));

  testWidgets('the count is drawn only while something is waiting', (
    tester,
  ) async {
    insert('s1');
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
    working('busy');
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

  testWidgets('Ctrl-click ticks a row, Shift-click ranges over the page, '
      'and Escape leaves selecting', (tester) async {
    insert('s1');
    insert('s2', age: const Duration(minutes: 1));
    insert('s3', age: const Duration(minutes: 2));
    final c = await pump(tester);
    c.read(explorerLensProvider.notifier).toggle(ExplorerLens.agents);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Chat s1'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(c.read(sessionSelectionProvider).ids, {'s1'});
    expect(find.byType(SessionSelectionBar), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('Chat s3'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(c.read(sessionSelectionProvider).ids, {'s1', 's2', 's3'});
    Focus.of(tester.element(find.text('Chat s2'))).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(c.read(sessionSelectionProvider).active, isFalse);
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
