import 'package:karmashala/src/app/shell/status_bar.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/agents/usage_fixtures.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// **What the model chip costs the row it sits in.**
///
/// The same obligation the usage chip carries, measured the same way: counted,
/// never timed, because the suite runs at `--concurrency=4` and a wall-clock
/// assertion over a few milliseconds is a coin toss.
///
/// What it measures (2026-09-02): a model change costs **1 chip build and 0
/// builds of the row's other items**. The row now carries a branch, a tab
/// count, a background count, an attention count, a model and a quota, so the
/// matrix cell that matters is 720x560 with both chips present.
class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

void main() {
  late FakeAgentUsageService service;

  setUp(() => service = FakeAgentUsageService());

  ProviderContainer barContainer() {
    final db = seedUsageDatabase();
    addTearDown(db.close);
    // A name long enough to compete for the row's width at 720px, which is
    // where a second chip's arrival is felt.
    RepositoryDao(db).insert(
      repository(id: 'r2', name: 'karmashala-app-desktop-shell', path: r'C:\s'),
    );
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        settingsControllerProvider.overrideWith(
          () => _StaticSettings(const Settings()),
        ),
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

  testWidgets('a model change repaints the chip and nothing else in the row', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();
    expect(find.text('default'), findsOneWidget);

    ShellStatusBar.debugItemBuildCount = 0;
    ModelChip.debugBuildCount = 0;
    UsageChip.debugBuildCount = 0;

    // Not running, so this is the deferred path — which is the one the status
    // bar will nearly always be on, and the one whose cost matters.
    container.read(sessionLauncherProvider).setModel('s1', 'opus');
    await tester.pump();

    expect(find.text('Opus'), findsOneWidget);
    expect(
      ModelChip.debugBuildCount,
      greaterThan(0),
      reason: 'the chip is the thing that changed',
    );
    expect(
      ShellStatusBar.debugItemBuildCount,
      0,
      reason:
          'the branch, the tab count and the panel toggle know nothing about '
          'a model and must not repaint for one',
    );
    expect(
      UsageChip.debugBuildCount,
      0,
      reason: 'and neither does the chip beside it',
    );
    await quiesce(tester, container);
  });

  testWidgets('a rename does not wake the chip', (tester) async {
    // The narrowing this control was asked for: the CLI store sweep renames
    // rows on a timer, without the user doing anything at all.
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();

    ModelChip.debugBuildCount = 0;
    container.read(sessionsRevisionProvider.notifier).changed(
      const SessionChange.renamed('s1'),
    );
    await tester.pump();

    expect(ModelChip.debugBuildCount, 0);
    await quiesce(tester, container);
  });

  testWidgets('the row holds at the minimum window with both chips on it', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    container.read(sessionLauncherProvider).setModel('s1', 'sonnet');
    await expectSurvivesWindowMatrix(
      tester,
      build: () => bar(container),
      because:
          'the status bar carries branch, tabs, background, attention, model '
          'and usage, and 720x560 is where the sixth item is felt',
    );
    await quiesce(tester, container);
  });

  testWidgets('and holds with the longest model name a shipped agent has', (
    tester,
  ) async {
    // `Gemini 3.7 Flash (Medium)` is a real slug from `agy models`, and the
    // widest thing this chip can be asked to draw.
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    container
        .read(sessionLauncherProvider)
        .setModel('s1', 'gemini-3.7-flash-medium');
    await expectSurvivesWindowMatrix(
      tester,
      build: () => bar(container),
      because: 'a long model name must cost the label, never the row',
    );
    await quiesce(tester, container);
  });
}
