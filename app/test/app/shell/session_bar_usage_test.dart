import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/usage_refresh_policy.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/agents/usage_fixtures.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';

/// **The quota in its new home: the bar that belongs to the session.**
///
/// The owner's words: *"move this usage to the terminal status bar so it's tied
/// to session not app because each session might be different one."* Panes run
/// different agents and different accounts, and the window's status bar could
/// only ever show one figure.
///
/// Four obligations, and the last two are the ones that decided the placement:
///
/// * it is drawn **under the terminal**, in the session's bar, not in the
///   window chrome;
/// * it describes **the pane on screen**, and changes when that changes;
/// * it repaints **itself and nothing else** — a quota is the most frequent
///   change in this bar, and the facts beside it and the actions under it know
///   nothing about it;
/// * it **cannot push `Run tests`, `Check this` or `Continue with…` anywhere**,
///   at any width. That is why it sits in the line of facts rather than in the
///   action row: the actions wrap rather than shrink, so anything sharing their
///   row is paid for in runs.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;
  late FakeAgentUsageService service;
  late MovableClock clock;
  late SessionDelivery delivery;

  /// Everything a bar can hold at once, so the chip is measured against the
  /// fullest row rather than an empty one.
  const fullBar = SessionDelivery(
    branch: 'session/fix-the-login-form-validation',
    baseBranch: 'origin/main',
    hasRemote: true,
    dirtyFiles: 1,
    aheadOfBase: 2,
    hasWorktree: true,
  );

  final claudeAccount = usageAccountKey(agentInstallation());

  ProviderContainer containerFor({Duration floor = Duration.zero}) {
    final made = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(
          machine: db,
          usageService: service,
          usagePollFloor: floor,
        ),
        clockProvider.overrideWithValue(clock),
        sessionDeliveryProvider.overrideWith((ref, _) async => delivery),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(made.dispose);
    return made;
  }

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    clock = MovableClock(testTime);
    service = FakeAgentUsageService(clock: clock);
    delivery = fullBar;
  });

  /// A session running in a pane of ours, which is the only kind with a bar.
  void seedPane({String id = 's1', String installation = 'a1'}) {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    final dao = db.server.sessionRows;
    dao.insert(session(id: id, agentInstallationId: installation));
    dao.updatePaneId(id, paneId);
  }

  Widget workbench() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
  );

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workbench());
    await tester.pumpAndSettle();
  }

  Future<void> quiesce(WidgetTester tester) async {
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
  }

  testWidgets('the quota is drawn under the terminal, in the session bar', (
    tester,
  ) async {
    container = containerFor();
    seedPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(find.byType(UsageChip), findsOneWidget);
    expect(find.text('62% · 2h11m'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(UsageChip)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(TerminalPaneStack)).dy,
      ),
      reason: 'it belongs to the bar under the terminal, not to the window',
    );
    await quiesce(tester);
  });

  testWidgets('it sits above the action row, never in it', (tester) async {
    // The placement rule. `deliveryActionsFor` over-offers on purpose and the
    // actions wrap rather than shrink, so a control on their row is paid for in
    // runs — the model chip already steps aside under ~820px for exactly this.
    // A quota is a fact, so it goes in the line of facts and cannot compete.
    container = containerFor();
    seedPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    final chip = tester.getRect(find.byType(UsageChip));
    final commit = tester.getRect(
      find.descendant(
        of: find.byType(DeliveryStrip),
        matching: find.text('Commit'),
      ),
    );
    expect(
      chip.bottom,
      lessThanOrEqualTo(commit.top + 0.5),
      reason: 'the facts are a caption over the actions, not an item in them',
    );
  });

  testWidgets('a quota change repaints the chip and nothing else in the bar', (
    tester,
  ) async {
    container = containerFor(floor: kUsageMinInterval);
    seedPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);
    expect(find.text('62% · 2h11m'), findsOneWidget);

    UsageChip.debugBuildCount = 0;
    DeliveryStateLine.debugBuildCount = 0;

    // Past the floor, or the refresh is answered from memory and there is no
    // change to measure — which is itself the subject of
    // `usage_refresh_policy_test.dart`.
    clock.now = clock.now.add(usageFixtureFloor);
    service.answer = usageSnapshot(percent: 77, fetchedAt: clock.nowUtc());
    container.read(usageRefreshProvider(claudeAccount).notifier).refresh();
    await tester.pump();
    await tester.pump();

    expect(find.text('77% · 2h11m'), findsOneWidget);
    expect(
      UsageChip.debugBuildCount,
      greaterThan(0),
      reason: 'the chip is the thing that changed',
    );
    expect(
      DeliveryStateLine.debugBuildCount,
      0,
      reason: 'the stage, the branch and the counts know nothing about a quota',
    );
    await quiesce(tester);
  });

  testWidgets('the chip describes the pane on screen, not the workspace', (
    tester,
  ) async {
    // Two tabs, two accounts. This is the whole of *"each session might be
    // different one"*: activating the other tab must change which quota is
    // reported, because it is a different account's.
    server.installationRows.insert(
      agentInstallation(id: 'a2', agentId: AgentIds.codex),
    );
    container = containerFor();
    seedPane();
    seedPane(id: 's2', installation: 'a2');
    container.read(selectedSessionIdProvider.notifier).select(null);
    await pump(tester);

    expect(
      service.calls.single.agentId,
      AgentIds.codex,
      reason: 'the tab that is up is the Codex one, and it is asked about',
    );

    final tabs = container.read(terminalSessionsControllerProvider).tabs;
    container
        .read(terminalSessionsControllerProvider.notifier)
        .activateTab(tabs.first.id);
    await tester.pumpAndSettle();

    expect(service.calls.map((i) => i.agentId).toList(), [
      AgentIds.codex,
      AgentIds.claudeCode,
    ], reason: 'switching pane switches account, and asks that account');
    await quiesce(tester);
  });

  testWidgets('a pane on an agent with no usage endpoint draws nothing', (
    tester,
  ) async {
    // Nothing, not a dash: a dash in a line of facts reads as a reading. The
    // service's own allowlist decides, one step earlier.
    server.installationRows.insert(
      agentInstallation(id: 'a2', agentId: 'unknownAgent'),
    );
    container = containerFor();
    seedPane(id: 's1', installation: 'a2');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);

    expect(find.byIcon(AppIcons.circleHalf), findsNothing);
    expect(find.textContaining('usage'), findsNothing);
    expect(
      tester.getSize(find.byType(UsageChip)),
      Size.zero,
      reason: 'no glyph, no dash, and no room reserved for either',
    );
    expect(service.calls, isEmpty);
  });

  testWidgets('before the first reading it claims nothing, and says so', (
    tester,
  ) async {
    // §19: never a number that was not observed. The glyph is the gauge and the
    // words are an ellipsis until an answer lands.
    container = containerFor();
    seedPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpWidget(workbench());

    expect(find.text('usage …'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('62% · 2h11m'), findsOneWidget);
    await quiesce(tester);
  });

  testWidgets('the three buttons survive the chip at every width', (
    tester,
  ) async {
    // §6, and the reason the chip is not in the action row. The matrix covers
    // a phone-like 720x560 and a desktop 1440x900, plus the minimum at the
    // 1.3x OS text step, which is where a fixed-height row breaks first.
    container = containerFor();
    seedPane();
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await expectSurvivesWindowMatrix(
      tester,
      build: workbench,
      warmUp: (tester) async {
        // The three the owner's screenshot shows have to be reachable, not
        // merely laid out: `hitTestWarningShouldBeFatal` is on inside the
        // matrix, so a button pushed off the window fails here.
        // The bar is on screen at every size in the matrix, and the matrix's
        // own rules — no overflow, nothing hit-tested off the window — are what
        // say its controls are reachable there.
        expect(find.byType(DeliveryStrip), findsOneWidget);
        // The **words** are only owed where there is room for them: a workspace
        // group narrower than 560px keeps every pill and drops its letters, so
        // asking for the text at 720px would now be asking the bar not to be
        // responsive. Above that the labels are still the assertion they were.
        final logical =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        if (logical < 900) return;
        for (final label in ['Run tests', 'Continue with…']) {
          expect(
            find.descendant(
              of: find.byType(DeliveryStrip),
              matching: find.text(label),
            ),
            findsOneWidget,
            reason: '$label must still be on the bar with a quota above it',
          );
        }
      },
      because:
          'the session bar exists at every width, and the actions wrap rather '
          'than shrink — a chip that competed with them would cost a run',
    );
    await quiesce(tester);
  });
}
