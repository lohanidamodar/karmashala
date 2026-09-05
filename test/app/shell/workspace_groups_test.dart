import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Two groups, two sessions, and the assertion that carries the whole weight:
/// **the neighbour does not move.**
///
/// A group's chrome could be wired to "the session the window is about" and
/// every single-group test would still pass — which is why a single-group test
/// is not evidence. With two groups the bug is loud: both bars show the same
/// repository state, the same model and the same usage, following whichever
/// pane was clicked last. So each case here reads *both* bars, and the switch
/// case asserts what stayed still rather than what changed.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        sessionTranscriptProvider.overrideWith((ref) => Stream.value(const [])),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        // One branch name per session, so each bar's own reading is legible in
        // the rendered tree.
        sessionDeliveryProvider.overrideWith(
          (ref, id) async => SessionDelivery(branch: 'branch-$id'),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.terminalGrid,
              evidence: const [],
              waiting: AgentWaitKind.unrecorded,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  /// A tab of its own running session [id].
  String openSessionTab(String id) {
    final tabId = terminals().openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.id == tabId)
        .layout
        .panes
        .single;
    final dao = SessionDao(db);
    dao.insert(session(id: id, title: 'Session $id'));
    dao.updatePaneId(id, paneId);
    return tabId;
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Two groups: `left` holding [first] and [third], `right` holding [second].
  ({String left, String right}) splitAndMove(String moved) {
    final right = terminals().splitWorkspace(SplitAxis.horizontal)!;
    terminals().moveTabToGroup(moved, right);
    final left = container
        .read(terminalSessionsControllerProvider)
        .workspace!
        .groups
        .map((group) => group.id)
        .firstWhere((id) => id != right);
    return (left: left, right: right);
  }

  testWidgets('each group\'s status bar reads its own session', (tester) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    final groups = splitAndMove(b);
    terminals().activateTab(a);

    await pump(tester);

    expect(
      find.text('branch-s1'),
      findsOneWidget,
      reason: 'the left group\'s bar, and only it',
    );
    expect(
      find.text('branch-s2'),
      findsOneWidget,
      reason: 'the right group\'s bar reads the tab it is showing',
    );
    expect(groups.left, isNot(groups.right));
  });

  testWidgets('switching a tab in one group leaves the other bar alone', (
    tester,
  ) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    final c = openSessionTab('s3');
    splitAndMove(b);
    terminals().activateTab(a);
    await pump(tester);
    expect(find.text('branch-s1'), findsOneWidget);
    expect(find.text('branch-s2'), findsOneWidget);

    terminals().activateTab(c);
    await tester.pumpAndSettle();

    // The assertion that matters. "The left bar moved to s3" would pass against
    // one app-wide focused session too; "the right bar still says s2" is what
    // only a per-group reading can satisfy.
    expect(find.text('branch-s2'), findsOneWidget);
    expect(find.text('branch-s3'), findsOneWidget);
    expect(find.text('branch-s1'), findsNothing);
  });

  testWidgets('a strip shows its own group\'s tabs and no others', (
    tester,
  ) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    openSessionTab('s3');
    splitAndMove(b);
    terminals().activateTab(a);

    await pump(tester);

    // Two chips in the left strip and one in the right. A strip reading the
    // window's whole tab list would draw three in each, for six.
    expect(find.byType(TerminalTabChip), findsNWidgets(3));
  });

  testWidgets('the room a split clears offers the ways to fill it', (
    tester,
  ) async {
    openSessionTab('s1');
    terminals().splitWorkspace(SplitAxis.horizontal);

    await pump(tester);

    expect(find.text('Empty group'), findsOneWidget);
    expect(find.text('New terminal'), findsOneWidget);
    expect(find.text('Close group'), findsOneWidget);
    // The tab that is already open is somewhere it could come from.
    expect(find.text('Move a tab here…'), findsOneWidget);
  });

  testWidgets('closing a group\'s last tab collapses it', (tester) async {
    final a = openSessionTab('s1');
    final b = openSessionTab('s2');
    splitAndMove(b);
    terminals().activateTab(a);
    await pump(tester);
    expect(find.byType(TerminalTabChip), findsNWidgets(2));

    terminals().closeTab(b);
    await tester.pumpAndSettle();

    expect(
      container.read(terminalSessionsControllerProvider).workspace!.groups,
      hasLength(1),
    );
    expect(find.byType(TerminalTabChip), findsOneWidget);
    expect(find.text('branch-s1'), findsOneWidget);
  });
}
