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

/// **The Overview tab, drawn**: the Board at desktop sizes and the list on a
/// phone, the strip's numbers, Done folded to today's count, and the peek's
/// actions reaching the paths every other surface uses.
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

  for (final (name, size) in [
    ('1440×900', const Size(1440, 900)),
    ('1024×768', const Size(1024, 768)),
  ]) {
    testBoard('$name: a Board of lanes and four columns', (tester) async {
      await pump(tester, size);

      expect(find.byKey(const ValueKey('overview-board')), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(card('p1', 'ask'), findsOneWidget);
      expect(card('p1', 'busy'), findsOneWidget);
      expect(card('p1', 'idle'), findsOneWidget);
      // Beta has nothing live: it folds into one line.
      expect(find.text('1 quiet project'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testBoard('390×844: one list grouped by state', (tester) async {
    await pump(tester, const Size(390, 844));

    expect(find.byKey(const ValueKey('overview-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('overview-board')), findsNothing);
    expect(find.text('Needs you · 1'), findsOneWidget);
    expect(card('p1', 'ask'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testBoard('the strip counts what the Board holds', (tester) async {
    await pump(tester, const Size(1440, 900));

    expect(find.text('1 need you'), findsOneWidget);
    expect(find.text('1 working'), findsOneWidget);
    expect(find.text('1 ready'), findsOneWidget);
    // No agent here reports cost over a protocol.
    expect(find.text('spend not recorded'), findsOneWidget);
  });

  testBoard("Done is today's count until opened; older ones behind Show "
      'all', (tester) async {
    await pump(tester, const Size(1440, 900));

    expect(card('p1', 'done'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('overview-done:p1')));
    await settle(tester);
    expect(card('p1', 'done'), findsOneWidget);
    expect(card('p1', 'old'), findsNothing);

    await tester.tap(find.text('Show all (1 older)'));
    await settle(tester);
    expect(card('p1', 'old'), findsOneWidget);
  });

  testBoard('a waiting card peeks into the ask path the dock uses', (
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

  testBoard("the peek's Resume and Archive reach the lists' own paths", (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));
    await tester.tap(find.byKey(const ValueKey('overview-done:p1')));
    await settle(tester);
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

  testBoard('the arrows move between cards and Enter peeks', (tester) async {
    final c = await pump(tester, const Size(1440, 900));
    // Click once to give the Board the keyboard, then close what it opened.
    await tester.tap(card('p1', 'busy'));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(find.byKey(const ValueKey('overview-peek:ask')), findsOneWidget);
    expect(c, isNotNull);
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
