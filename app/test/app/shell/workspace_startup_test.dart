import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../support/workspace_mirror.dart';

/// The whole shell, launched into a **stored split workspace** — which is the
/// launch most users get, and the one no other test performed end to end.
///
/// Two things only this shape can catch. A group is a fraction of the window,
/// so every row inside one has to survive a width the shell never used to hand
/// it; and the restore path is where a provider is most likely to be written
/// while the tree is still building, which Riverpod refuses loudly in debug and
/// swallows in release.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.override();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  /// The bar's own content is what a narrow group has to fit, so the delivery
  /// state is the **fullest** one rather than the empty default: a branch, a
  /// dirty tree, work to push, and a fork plan that offers "Continue with…".
  final delivery = SessionDelivery(
    branch: 'feature/the-long-branch-name',
    baseBranch: 'origin/main',
    upstream: 'origin/feature/the-long-branch-name',
    hasRemote: true,
    dirtyFiles: 3,
    aheadOfBase: 2,
    unpushed: 2,
  );
  final continuation = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(
      descriptor: AgentRegistry.builtIn.byId(AgentIds.claudeCode),
      agentName: 'Claude Code',
      externalSessionId: 'ext-1',
    ),
  );

  ProviderContainer shellContainer() {
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(database: db),
        // Everything that would otherwise reach the host or poll a file: a
        // spinner that never stops is a `pumpAndSettle` that never returns.
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        sessionDeliveryProvider.overrideWith((ref, _) async => delivery),
        sessionContinuationProvider.overrideWith((ref, _) => continuation),
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
    return container;
  }

  /// Leaves a two-group workspace in the store and disposes the container that
  /// wrote it, the way quitting the app does. Each group's tab runs a session,
  /// which is what pulls the delivery strip, the model and the usage figure
  /// into the first frame.
  void storeASplitWorkspace() {
    final first = fakeTerminalContainer(database: db);
    final controller = first.read(terminalSessionsControllerProvider.notifier);
    final dao = SessionDao(db);

    void seed(String id, String tabId) {
      final paneId = first
          .read(terminalSessionsControllerProvider)
          .tabs
          .firstWhere((tab) => tab.id == tabId)
          .layout
          .panes
          .single;
      dao.insert(session(id: id, title: 'Session $id'));
      dao.updatePaneId(id, paneId);
    }

    seed('s1', controller.openTab(TerminalProfile.powerShell));
    controller.splitWorkspace(SplitAxis.horizontal);
    seed('s2', controller.openTab(TerminalProfile.commandPrompt));
    controller.persistLayout();
    first.dispose();
  }

  Future<ProviderContainer> launch(WidgetTester tester, Size size) async {
    storeASplitWorkspace();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = shellContainer();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    // Bounded pumps, not `pumpAndSettle`: a terminal pane blinks its cursor for
    // ever, so nothing in this tree ever settles. Four frames is enough for the
    // first layout, the post-frame work the shell schedules, and the two
    // futures the bar waits on.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    return container;
  }

  testWidgets('a split group fits its own status bar at every window width', (
    tester,
  ) async {
    // 1000px with the Explorer and the side rail leaves each of two groups
    // under 400 — the width the owner reported the bar overflowing at, and the
    // normal case once the workspace is divided rather than an edge one.
    final container = await launch(tester, const Size(1000, 700));

    expect(
      container.read(terminalSessionsControllerProvider).workspace!.groups,
      hasLength(2),
    );
    // The bar has to have actually drawn its fullest content, or "no overflow"
    // is a statement about an empty box. `DeliveryStrip` offers a commit while
    // the tree is dirty, and it is the pill the narrow row keeps.
    expect(find.byType(DeliveryStrip), findsWidgets);
    expect(find.byType(PermissionModeChip), findsWidgets);
    // An overflow is thrown during layout, so it arrives as an exception rather
    // than as anything a finder could see.
    expect(tester.takeException(), isNull);
  });

  testWidgets('and at the smallest window the app supports', (tester) async {
    await launch(tester, const Size(720, 560));

    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow group keeps every control and gives up the words', (
    tester,
  ) async {
    await launch(tester, const Size(1000, 700));

    // The toggle is the clearest witness: both halves are still there and both
    // are still labelled to a screen reader, but the two words are gone.
    expect(find.text('Terminal'), findsNothing);
    expect(find.text('Chat'), findsNothing);
    expect(find.byTooltip('Terminal view'), findsWidgets);
    expect(find.byTooltip('Chat view'), findsWidgets);
  });

  testWidgets('a group with room to spell them keeps the words', (
    tester,
  ) async {
    storeASplitWorkspace();
    tester.view.physicalSize = const Size(2200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = shellContainer();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Terminal'), findsWidgets);
    expect(find.text('Chat'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('launching into a stored split writes no provider mid-build', (
    tester,
  ) async {
    final container = await launch(tester, const Size(1440, 900));

    expect(tester.takeException(), isNull);
    expect(
      container.read(terminalSessionsControllerProvider).workspace!.groups,
      hasLength(2),
    );
  });
}
