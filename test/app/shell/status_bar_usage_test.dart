import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/app/shell/status_bar.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/usage_refresh_policy.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/agents/usage_fixtures.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// **What the account quota costs the window's own row — which is now
/// nothing.**
///
/// The chip lived here and has moved to the session's bar under the terminal,
/// for the reason the model chip moved before it: *"tied to session not app
/// because each session might be different one."* A quota belongs to an
/// `(agent, environment)` account, and a window holds panes on several — so one
/// figure in the window chrome reported whichever session the app believed was
/// focused and attributed its remaining quota to every pane beside it.
///
/// So this file's obligation inverts, and is worth keeping either way. This row
/// must not repaint for a quota **at all** now — it has no chip of its own to
/// justify it — and it must still hold at 720x560 with the chip gone and the
/// state group taking the middle group's room. `session_bar_usage_test.dart`
/// measures the chip in its new home.
///
/// Counted, never timed, for the reason every other cost test in this suite
/// gives: the suite runs at `--concurrency=4`, so a wall-clock assertion over a
/// few milliseconds is a coin toss, while widget builds are countable exactly.
void main() {
  late FakeAgentUsageService service;

  /// The database `barContainer` seeded, so a test that has to reach past the
  /// providers — writing a pane id onto a session row — writes into the one the
  /// container is reading.
  late AppDatabase seeded;

  setUp(() => service = FakeAgentUsageService());

  ProviderContainer barContainer() {
    final db = seedUsageDatabase();
    seeded = db;
    addTearDown(db.close);
    // A name long enough to compete for the row's width at 720px, which is
    // where the loss of the middle group is felt.
    RepositoryDao(db).insert(
      repository(id: 'r2', name: 'karmashala-app-desktop-shell', path: r'C:\s'),
    );
    final container = ProviderContainer(
      overrides: [
        // A real floor: this file still has to prove a tick cannot reach the
        // row, and a zero floor would arm nothing to prove it with.
        ...fakeTerminalOverrides(
          database: db,
          usageService: service,
          usagePollFloor: kUsageMinInterval,
        ),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r2');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    return container;
  }

  /// Puts session `s1` in the terminal tab on screen and takes the Explorer's
  /// selection away — the state a user is in after activating a tab whose
  /// session has no pane yet.
  void showInTerminalOnly(ProviderContainer container) {
    final opened = container
        .read(terminalSessionsControllerProvider.notifier)
        .openAgentTab(
          const AgentPaneLaunch(
            agentId: AgentIds.claudeCode,
            executable: r'C:\Users\me\.bin\claude.exe',
            arguments: [],
            workingDirectory: r'C:\src\demo\app',
            sessionId: 's1',
            title: 'Session',
          ),
        );
    SessionDao(seeded).updatePaneId('s1', opened.paneId);
    container.read(selectedSessionIdProvider.notifier).select(null);
  }

  Widget bar(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: Column(children: [Spacer(), ShellStatusBar()])),
    ),
  );

  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
  }

  testWidgets('the quota is not on this row any more, and neither is its '
      'timer', (tester) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();

    expect(find.byType(UsageChip), findsNothing);
    expect(find.textContaining('62%'), findsNothing);
    expect(
      service.calls,
      isEmpty,
      reason: 'the window chrome asks no vendor anything',
    );
    await quiesce(tester, container);
  });

  testWidgets('a quota change cannot reach the row at all', (tester) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();

    ShellStatusBar.debugItemBuildCount = 0;
    UsageChip.debugBuildCount = 0;

    service.answer = usageSnapshot(percent: 77);
    // Nothing watches the policy here, so there is nothing to refresh — which
    // is the assertion. Five intervals of a real floor produce no build of
    // anything on this row.
    await tester.pump(kUsageMinInterval * 5);
    await tester.pump();

    expect(
      ShellStatusBar.debugItemBuildCount,
      0,
      reason:
          'the branch, the tab count and the panel toggle know nothing '
          'about a quota and must not repaint for one',
    );
    expect(UsageChip.debugBuildCount, 0, reason: 'there is no chip here');
    await quiesce(tester, container);
  });

  testWidgets('the row still holds at the minimum window without the chip', (
    tester,
  ) async {
    final container = barContainer();
    await expectSurvivesWindowMatrix(
      tester,
      build: () => bar(container),
      because:
          'the status bar competes for width at 720x560, and losing the middle '
          'group changes what the two that are left are allotted',
    );
    await quiesce(tester, container);
  });

  testWidgets('the row survives a session that is only in the terminal', (
    tester,
  ) async {
    // The regression the chip used to guard: selection is dropped on purpose
    // whenever a selected session has no live pane. Nothing on this row reads
    // the session any more, so it must simply be untroubled by it.
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pumpAndSettle();

    showInTerminalOnly(container);
    await tester.pumpAndSettle();

    expect(find.byType(ShellStatusBar), findsOneWidget);
    expect(find.byType(UsageChip), findsNothing);
    await quiesce(tester, container);
  });

  testWidgets('the toggle rides the right edge and the state group holds it', (
    tester,
  ) async {
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pumpAndSettle();

    final row = tester.getRect(find.byType(ShellStatusBar));
    // The whole item, not its glyph: the label sits to the right of the icon,
    // so measuring the icon would call the item short by the width of whatever
    // the panel is currently called.
    final toggle = tester.getRect(
      find
          .ancestor(
            of: find.byIcon(AppIcons.sidebarSimple),
            matching: find.byType(InkWell),
          )
          .first,
    );

    expect(
      row.right - toggle.right,
      lessThan(24),
      reason: 'the panel toggle is the last item on the row',
    );
    await quiesce(tester, container);
  });

  testWidgets('the state group reaches the right edge of a wide window', (
    tester,
  ) async {
    final container = barContainer();
    // Wide, because this is invisible at 800: the narrower the row, the less
    // free space there is to be lost, and the bug is *unused free space*. On a
    // 1600px window it came to 500 blank pixels past the panel toggle.
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(bar(container));
    await tester.pumpAndSettle();

    final row = tester.getRect(find.byType(ShellStatusBar));
    final toggle = tester.getRect(
      find
          .ancestor(
            of: find.byIcon(AppIcons.sidebarSimple),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(
      row.right - toggle.right,
      lessThan(24),
      reason: 'the group ends where the row ends, at any width',
    );
    await quiesce(tester, container);
  });
}
