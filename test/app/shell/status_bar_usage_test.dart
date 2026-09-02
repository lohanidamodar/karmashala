import 'package:karmashala/src/app/shell/status_bar.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_refresh_policy.dart';
import 'package:karmashala/src/features/agents/data/agent_usage_service.dart';
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

/// **What the usage chip costs the row it sits in.**
///
/// `status_bar.dart` carries a note about the two terminal counts: "a process
/// exiting anywhere used to repaint this whole row". The chip must not
/// reintroduce that in the other direction — a quota moving is the most
/// frequent change on the row, and it must repaint one item and no others.
///
/// Counted, never timed, for the reason every other cost test in this suite
/// gives: the suite runs at `--concurrency=4`, so a wall-clock assertion over a
/// few milliseconds is a coin toss, while widget builds are countable exactly.
///
/// What it measures (2026-09-02): a usage change costs **1 chip build and 0
/// builds of the row's other items**; a blurred window costs **0 of either and
/// no request at all**, five intervals deep.
void main() {
  late FakeAgentUsageService service;

  setUp(() => service = FakeAgentUsageService());

  ProviderContainer barContainer() {
    final db = seedUsageDatabase();
    addTearDown(db.close);
    // A name long enough to compete for the row's width at 720px, which is
    // where the chip's arrival is felt.
    RepositoryDao(db).insert(
      repository(id: 'r2', name: 'karmashala-app-desktop-shell', path: r'C:\s'),
    );
    final container = ProviderContainer(
      overrides: [
        // A real interval: this file is the one that is about the tick.
        ...fakeTerminalOverrides(
          database: db,
          usageRefreshInterval: kUsageRefreshInterval,
        ),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentUsageServiceProvider.overrideWithValue(service),
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

  testWidgets('a usage change repaints the chip and nothing else in the row', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();
    expect(find.text('62% · 2h11m'), findsOneWidget);

    ShellStatusBar.debugItemBuildCount = 0;
    UsageChip.debugBuildCount = 0;

    service.answer = usageSnapshot(percent: 77);
    container.read(usageRefreshProvider.notifier).refresh();
    await tester.pump();
    await tester.pump();

    expect(find.text('77% · 2h11m'), findsOneWidget);
    expect(
      UsageChip.debugBuildCount,
      greaterThan(0),
      reason: 'the chip is the thing that changed',
    );
    expect(
      ShellStatusBar.debugItemBuildCount,
      0,
      reason:
          'the branch, the tab count and the panel toggle know nothing '
          'about a quota and must not repaint for one',
    );
    await quiesce(tester, container);
  });

  testWidgets('a blurred window costs the row nothing at all', (tester) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();

    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
    ShellStatusBar.debugItemBuildCount = 0;
    UsageChip.debugBuildCount = 0;
    final fetches = service.calls.length;

    await tester.pump(kUsageRefreshInterval * 5);
    await tester.pump();

    expect(service.calls.length, fetches, reason: 'zero polling while away');
    expect(UsageChip.debugBuildCount, 0);
    expect(ShellStatusBar.debugItemBuildCount, 0);
    await quiesce(tester, container);
  });

  testWidgets('the row still holds at the minimum window with the chip on it', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await expectSurvivesWindowMatrix(
      tester,
      build: () => bar(container),
      because:
          'the status bar already competes for width at 720x560, and the chip '
          'adds a glyph, a percent and a countdown to the busiest end of it',
    );
    await quiesce(tester, container);
  });

  testWidgets('the muted chip holds at the minimum window too', (tester) async {
    // The longest state the chip can be in is not the number — it is the
    // failure, whose whole sentence goes in the tooltip.
    service.failure = UsageException(
      'Access token expired. Run the agent once to refresh, then retry.',
    );
    final container = barContainer();
    await expectSurvivesWindowMatrix(
      tester,
      build: () => bar(container),
      because: 'a muted chip must not change the row it sits in',
    );
    await quiesce(tester, container);
  });
}
