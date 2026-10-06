import 'package:agent_cli/process.dart' show localHostEnvironment;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/logs_tab_view.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/logging/server_log_tail.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **The log tail is a workbench tab**, opened the way Usage and Stores are:
/// one tab however often it is asked for, named and drawn like them.
void main() {
  late CountingLayoutStore db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = CountingLayoutStore();
    server = FakeDataServer();
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
  });
  tearDown(() => db.close());

  Future<ProviderContainer> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(layoutStore: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        serverLogTailProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    // Bounded pumps: a terminal cursor blinks for ever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    return container;
  }

  WidgetRef refOf(WidgetTester tester) =>
      tester.element(find.byType(WorkbenchView)) as WidgetRef;

  List<String> logsTabsIn(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.panes.any(isLogsPane)) tab.id,
  ];

  testWidgets('opens one tab, and opening it again focuses that one', (
    tester,
  ) async {
    final container = await launch(tester);

    openLogsTab(refOf(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(LogsTabView), findsOneWidget);
    final tabId = logsTabsIn(container).single;
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    expect(controller.titleForTab(tabId), 'Logs');

    // Something else in front, then the second ask brings it back.
    openSettingsTab(refOf(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    openLogsTab(refOf(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(logsTabsIn(container), [tabId]);
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      tabId,
    );
    expect(find.byType(LogsTabView), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('Settings → Diagnostics opens it', (tester) async {
    final container = await launch(tester);
    openSettingsTab(refOf(tester), anchor: SettingsAnchor.debugMode);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final button = find.widgetWithText(OutlinedButton, 'Open Logs');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(logsTabsIn(container), hasLength(1));
    expect(find.byType(LogsTabView), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });

  test('a keymap can bind it: Open Logs is a named command', () {
    final command = unboundShellCommands.where((c) => c.command == 'logs.open');
    expect(command, hasLength(1));
    expect(command.single.intent, isA<OpenLogsIntent>());
  });
}
