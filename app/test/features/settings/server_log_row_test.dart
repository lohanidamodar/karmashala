import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/logging/diagnostics_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/settings/presentation/diagnostics_page.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';

/// Settings → Diagnostics → Log file names this machine's server log and
/// opens it; a client that hosts no server shows nothing of it.
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

  Future<FakeCommandRunner> pump(
    WidgetTester tester, {
    required bool hostsServer,
  }) async {
    final runner = FakeCommandRunner();
    final server = FakeDataServer();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        diagnosticsProvider.overrideWithValue(
          Diagnostics(echoToConsole: false),
        ),
        clientCapabilitiesProvider.overrideWithValue(
          client(hostsServer: hostsServer),
        ),
        localServerDataDirectoryProvider.overrideWith((ref) async => data),
        hostCommandRunnerProvider.overrideWithValue(runner),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: LogFileSection())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return runner;
  }

  testWidgets('a desktop that hosts its server shows the log and opens it', (
    tester,
  ) async {
    final log = File(p.join(data.path, 'logs', 'server.log'))
      ..createSync(recursive: true)
      ..writeAsStringSync('serving\n');
    final runner = await pump(tester, hostsServer: true);

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
    final runner = await pump(tester, hostsServer: true);

    await tester.tap(find.text('Open server log'));
    await tester.pumpAndSettle();

    expect(runner.requests, isEmpty);
    expect(
      find.text('The server has not written its log yet.'),
      findsOneWidget,
    );
  });

  testWidgets('a phone shows nothing of a server log', (tester) async {
    await pump(tester, hostsServer: false);

    expect(find.text('Server log'), findsNothing);
    expect(find.text('Open server log'), findsNothing);
  });
}
