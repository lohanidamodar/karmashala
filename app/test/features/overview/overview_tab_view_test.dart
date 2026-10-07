import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The Overview tab, drawn** over the real data path: the counters and a
/// tile per project at desktop and phone sizes, the counters filtering, the
/// one filter control and its chips, and the peek's actions reaching the paths
/// every other surface uses.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Directory dir;
  late _SpyActions actions;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('ks-overview-view');
  });
  tearDownAll(() => dir.delete(recursive: true));

  WatchedSession watch(String row) => WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'cli-$row'),
    label: row,
    openId: row,
    imported: false,
  );

  void insert(
    String id, {
    SessionStatus status = SessionStatus.running,
    Duration age = const Duration(hours: 1),
    String repo = 'r1',
  }) => db.server.sessionRows.insert(
    Session(
      id: id,
      repositoryId: repo,
      agentInstallationId: 'a1',
      title: 'Chat $id',
      useWorktree: false,
      status: status,
      createdAt: testTime.subtract(age),
    ),
  );

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
    server.repositoryRows
      ..insert(
        repository(
          id: 'r1',
          projectId: 'p1',
          name: 'alpha',
          path: r'C:\src\alpha',
        ),
      )
      ..insert(
        repository(
          id: 'r2',
          projectId: 'p2',
          name: 'beta',
          path: r'C:\src\beta',
        ),
      );
    insert('ask');
    insert('busy');
    insert('idle', status: SessionStatus.idle);
    insert('done', status: SessionStatus.completed);
    insert(
      'old',
      status: SessionStatus.completed,
      age: const Duration(days: 3),
    );
    insert('beta-done', status: SessionStatus.completed, repo: 'r2');
  });

  Future<ProviderContainer> pump(WidgetTester tester, Size size) async {
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
        overviewPrefsDirectoryProvider.overrideWithValue(() async => dir),
        explorerActionsProvider.overrideWith(
          (ref) => actions = _SpyActions(ref),
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
          home: const Scaffold(body: OverviewTabView()),
        ),
      ),
    );
    server.attention.statusOf(
      'busy',
      AgentActivityStatus.working,
      sessionId: 'cli-busy',
      label: 'busy',
      // A screen reading: no evidence age, so the lens arms no quiet timer.
      source: AgentStatusSource.terminalGrid,
    );
    server.attention.setInbox(
      AttentionInbox(
        items: [
          InboxItem(
            session: watch('ask'),
            kind: InboxItemKind.needsApproval,
            at: testTime,
          ),
        ],
      ),
      waiting: [
        SessionAttention(session: watch('ask'), kind: AttentionKind.needsInput),
      ],
    );
    await settle(tester);
    return container;
  }

  Finder card(String lane, String id) =>
      find.byKey(ValueKey('overview:$lane:$id'));

  Finder counter(BoardColumn column) =>
      find.byKey(ValueKey('overview-counter:${column.name}'));

  for (final (name, size) in [
    ('1440×900', const Size(1440, 900)),
    ('1024×768', const Size(1024, 768)),
    ('390×844', const Size(390, 844)),
  ]) {
    testBoard('$name: counters, then a tile per project with its marks', (
      tester,
    ) async {
      await pump(tester, size);

      expect(find.byKey(const ValueKey('overview-mission')), findsOneWidget);
      for (final column in BoardColumn.values) {
        expect(counter(column), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('overview-lane:p1')), findsOneWidget);
      expect(card('p1', 'ask'), findsOneWidget);
      expect(card('p1', 'busy'), findsOneWidget);
      expect(card('p1', 'idle'), findsOneWidget);
      // Done today is a mark; what ended before today is not.
      expect(card('p1', 'done'), findsOneWidget);
      expect(card('p1', 'old'), findsNothing);
      // Beta only finished today: still a tile, not a quiet line.
      expect(find.byKey(const ValueKey('overview-lane:p2')), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-quiet-lanes')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testBoard('the counters count what the tiles hold, spend left out', (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));

    expect(find.bySemanticsLabel(RegExp(r'^Needs you, 1, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Working, 1, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Ready, 1, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Done today, 2, ')), findsOneWidget);
    // No agent here reports cost over a protocol: nothing is said about it.
    expect(find.textContaining('spend'), findsNothing);
    expect(find.byKey(const ValueKey('overview-facts')), findsNothing);
  });

  testBoard('a counter shows only its state; tapped again, all of them', (
    tester,
  ) async {
    final c = await pump(tester, const Size(1440, 900));

    await tester.tap(counter(BoardColumn.working));
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.columns, {BoardColumn.working});
    expect(card('p1', 'busy'), findsOneWidget);
    expect(card('p1', 'ask'), findsNothing);
    expect(find.byKey(const ValueKey('overview-lane:p2')), findsNothing);
    // The other counters keep their numbers.
    expect(find.bySemanticsLabel(RegExp(r'^Needs you, 1, ')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Working, 1, showing only these')),
      findsOneWidget,
    );

    await tester.tap(counter(BoardColumn.working));
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.columns, isNull);
    expect(card('p1', 'ask'), findsOneWidget);
  });

  testBoard('the filter control sets the prefs; a chip clears its filter', (
    tester,
  ) async {
    final c = await pump(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('overview-active-filters')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('overview-filter-button')));
    await settle(tester);
    expect(find.byKey(const ValueKey('overview-filter-panel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-filter-project:p2')));
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.projects, {'p1'});
    await tester.tap(find.text('Machine').last);
    await settle(tester);
    expect(c.read(overviewPrefsProvider).groupBy, OverviewGroupBy.machine);
    await tester.tap(find.text('Project').last);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('Projects: Alpha'), findsOneWidget);
    expect(find.byKey(const ValueKey('overview-lane:p2')), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('overview-active-filter:projects')),
        matching: find.byTooltip('Clear Projects: Alpha'),
      ),
    );
    await settle(tester);
    expect(c.read(overviewPrefsProvider).filter.projects, isNull);
    expect(find.byKey(const ValueKey('overview-active-filters')), findsNothing);
    expect(find.byKey(const ValueKey('overview-lane:p2')), findsOneWidget);
  });

  testBoard('a waiting mark peeks into the ask path the dock uses', (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));

    await tester.tap(card('p1', 'ask'));
    await settle(tester);

    expect(find.byKey(const ValueKey('overview-peek')), findsOneWidget);
    expect(find.byType(ApprovalRequestCard), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const ValueKey('overview-peek')), findsNothing);
  });

  testBoard('the headline peeks the session that matters most', (tester) async {
    await pump(tester, const Size(1440, 900));

    await tester.tap(find.byKey(const ValueKey('overview-headline:ask')));
    await settle(tester);
    expect(find.byKey(const ValueKey('overview-peek:ask')), findsOneWidget);
  });

  testBoard("the peek's Resume and Archive reach the lists' own paths", (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));
    await tester.tap(card('p1', 'done'));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('overview-peek-open')));
    await settle(tester);
    expect(actions.opened, ['done']);
    expect(find.text('Resume'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('overview-peek-archive')));
    await settle(tester);
    expect(
      server.requests.where((k) => k == SessionsArchive.name),
      hasLength(1),
    );
  });

  testBoard('the arrows move between marks and Enter peeks', (tester) async {
    await pump(tester, const Size(1440, 900));
    // Click once to give the Board the keyboard, then close what it opened.
    await tester.tap(card('p1', 'busy'));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(find.byKey(const ValueKey('overview-peek:ask')), findsOneWidget);
  });
}

/// Bounded: an ask's shield breathes for ever.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _SpyActions extends ExplorerActions {
  _SpyActions(super.ref);

  final List<String> opened = [];

  @override
  Future<ExplorerResult> openNative(String sessionId) async {
    opened.add(sessionId);
    return const ExplorerResult(ExplorerOutcome.selected);
  }
}

/// A widget test that unmounts the tab before it ends, so the Agents lens's
/// own quiet timer is cancelled with the providers that held it.
void testBoard(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
