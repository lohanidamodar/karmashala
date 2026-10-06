import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/logs_tab_view.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/logging/diagnostics_providers.dart';
import 'package:karmashala/src/core/logging/server_log_tail.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/server/presentation/server_log_section.dart';
import 'package:karmashala/src/features/settings/application/settings_tab.dart';
import 'package:karmashala/src/features/settings/presentation/diagnostics_page.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';
import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

/// Settings → Server → Log names this machine's server log, opens it, and
/// opens the Logs tab on it; Diagnostics keeps a link here rather than a
/// second copy. A client that hosts no server shows nothing of it.
void main() {
  late Directory data;

  setUp(() => data = Directory.systemTemp.createTempSync('server_log_row'));
  tearDown(() => removeTempDirectory(data));

  ClientCapabilities client({required bool hostsServer}) => ClientCapabilities(
    systemIntegration: hostsServer,
    osToasts: hostsServer,
    localNotifications: !hostsServer,
    localDevices: hostsServer,
    externalApps: hostsServer,
    fileDrop: hostsServer,
    relaunch: hostsServer,
    density: hostsServer ? UiDensity.pointer : UiDensity.touch,
    hostsServer: hostsServer,
    multicastLock: false,
    mediaPlayback: hostsServer,
    deviceName: 'test',
    camera: !hostsServer,
  );

  Future<(FakeCommandRunner, ProviderContainer)> pump(
    WidgetTester tester, {
    required bool hostsServer,
    Widget section = const ServerLogSection(),
  }) async {
    final runner = FakeCommandRunner();
    final server = FakeDataServer();
    final layouts = CountingLayoutStore();
    addTearDown(layouts.close);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          layoutStore: layouts,
          data: await server.override(),
        ),
        diagnosticsProvider.overrideWithValue(
          Diagnostics(echoToConsole: false),
        ),
        clientCapabilitiesProvider.overrideWithValue(
          client(hostsServer: hostsServer),
        ),
        localServerDataDirectoryProvider.overrideWith((ref) async => data),
        hostCommandRunnerProvider.overrideWithValue(runner),
        serverLogTailProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: section)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (runner, container);
  }

  testWidgets('a desktop that hosts its server shows the log and opens it', (
    tester,
  ) async {
    final log = File(p.join(data.path, 'logs', 'server.log'))
      ..createSync(recursive: true)
      ..writeAsStringSync('serving\n');
    final (runner, _) = await pump(tester, hostsServer: true);

    expect(find.text(SettingsAnchor.serverLog.heading), findsOneWidget);
    expect(find.text('Server log'), findsOneWidget);
    expect(find.text(log.path), findsOneWidget);

    await tester.tap(find.text('Open server log'));
    await tester.pumpAndSettle();

    final manager = HostFileManager.forHost()!;
    expect(runner.requests, hasLength(1));
    expect(
      runner.requests.single.arguments,
      RevealInFileManager.requestFor(manager, log.path).arguments,
    );
  });

  testWidgets('a log not written yet says so instead of opening nothing', (
    tester,
  ) async {
    final (runner, _) = await pump(tester, hostsServer: true);

    await tester.tap(find.text('Open server log'));
    await tester.pumpAndSettle();

    expect(runner.requests, isEmpty);
    expect(
      find.text('The server has not written its log yet.'),
      findsOneWidget,
    );
  });

  testWidgets('Open in Logs opens the Logs tab with Server selected', (
    tester,
  ) async {
    final (_, container) = await pump(tester, hostsServer: true);

    await tester.tap(find.text('Open in Logs'));
    await tester.pump();

    expect(container.read(logsTabSourceProvider), LogSource.server);
    expect(
      [
        for (final tab in container.read(terminalSessionsControllerProvider).tabs)
          if (tab.layout.panes.any(isLogsPane)) tab.id,
      ],
      hasLength(1),
    );
  });

  testWidgets('a phone shows nothing of a server log', (tester) async {
    await pump(tester, hostsServer: false);

    expect(find.text('Server log'), findsNothing);
    expect(find.text('Open server log'), findsNothing);
  });

  testWidgets('Diagnostics links to the row on Server instead of a copy', (
    tester,
  ) async {
    final (_, container) = await pump(
      tester,
      hostsServer: true,
      section: const LogFileSection(),
    );

    expect(find.text('Open server log'), findsNothing);
    await tester.tap(find.text('Open Server'));
    await tester.pump();
    expect(
      container.read(settingsTabSectionProvider)?.anchor,
      SettingsAnchor.serverLog,
    );
  });
}
