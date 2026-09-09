import 'package:karmashala/src/app/shell/status_bar.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
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

/// **What a model change costs the window's own row — which is now nothing.**
///
/// The model chip used to live here, beside the account quota, and this file
/// measured that it repainted itself and none of its neighbours. The chip has
/// since moved to the session's bar, where it belongs: which model a session
/// runs under is a fact about that session, not about the window.
///
/// So the obligation inverts, and is worth keeping either way. The row must not
/// repaint for a model change *at all* now — no chip of its own to justify it —
/// and it must still hold at 720x560. The quota has since followed the model
/// out of this row for the same reason, so both halves of the middle group are
/// gone and this file watches that neither comes back. Counted, never timed,
/// because the suite runs at `--concurrency=4` and a wall-clock assertion over
/// a few milliseconds is a coin toss.
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
        ...fakeTerminalOverrides(database: db, usageService: service),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        settingsControllerProvider.overrideWith(
          () => _StaticSettings(const Settings()),
        ),
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

  testWidgets('a model change does not reach the window row at all', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();

    // Gone from here on purpose. The model is a session control and lives in
    // the session's bar with the permission mode and the delivery actions.
    expect(find.byType(ModelChip), findsNothing);

    ShellStatusBar.debugItemBuildCount = 0;
    ModelChip.debugBuildCount = 0;
    UsageChip.debugBuildCount = 0;

    container.read(sessionLauncherProvider).setModel('s1', 'opus');
    await tester.pump();

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
      reason: 'and the quota has followed it out of this row entirely',
    );
    await quiesce(tester, container);
  });

  testWidgets('a rename does not wake the row either', (tester) async {
    // The narrowing this row was asked for: the CLI store sweep renames rows on
    // a timer, without the user doing anything at all.
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    await tester.pumpWidget(bar(container));
    await tester.pump();

    ShellStatusBar.debugItemBuildCount = 0;
    UsageChip.debugBuildCount = 0;
    container
        .read(sessionsRevisionProvider.notifier)
        .changed(const SessionChange.renamed('s1'));
    await tester.pump();

    expect(ShellStatusBar.debugItemBuildCount, 0);
    expect(UsageChip.debugBuildCount, 0);
    await quiesce(tester, container);
  });

  testWidgets('the row holds at the minimum window with both chips gone', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    container.read(sessionLauncherProvider).setModel('s1', 'sonnet');
    await expectSurvivesWindowMatrix(
      tester,
      build: () => bar(container),
      because:
          'the status bar carries branch, tabs, background, attention and the '
          'quota, and 720x560 is where the last item is felt',
    );
    await quiesce(tester, container);
  });

  testWidgets('and a long model name cannot reach this row to widen it', (
    tester,
  ) async {
    // `Gemini 3.7 Flash (Medium)` is a real slug from `agy models`, and the
    // widest thing the chip can be asked to draw. It used to be this row's
    // problem; the session bar owns it now, where it is the one label that
    // gives way.
    service.answer = usageSnapshot(percent: 62);
    final container = barContainer();
    container
        .read(sessionLauncherProvider)
        .setModel('s1', 'gemini-3.7-flash-medium');
    await expectSurvivesWindowMatrix(
      tester,
      build: () => bar(container),
      because: 'no model name belongs in the window chrome any more',
    );
    await quiesce(tester, container);
  });
}
