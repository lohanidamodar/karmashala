import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/server/application/server_overview.dart';
import 'package:karmashala/src/features/server/presentation/server_status_section.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/application/settings_tab.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/ssh/application/host_install_controller.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';

/// Settings → Server → Status and controls: what this machine's server is
/// doing, and Restart and Stop, which confirm first and say what they end.
void main() {
  final now = DateTime.utc(2026, 10, 6, 12);

  ServerOverview running({
    String? version = '1.31.1',
    int? live = 2,
    int? ended = 5,
    String? controlsRefusal,
  }) => ServerOverview(
    state: ServerRunState.running,
    serverVersion: version,
    appVersion: '1.31.1',
    startedAt: now.subtract(const Duration(hours: 3, minutes: 12)),
    liveSessions: live,
    endedSessions: ended,
    dataFolder: '/data/karmashala',
    socketPath: '/data/karmashala/host.sock',
    controlsRefusal: controlsRefusal,
  );

  ClientCapabilities client({required bool desktop}) => ClientCapabilities(
    systemIntegration: desktop,
    osToasts: desktop,
    localNotifications: !desktop,
    localDevices: desktop,
    externalApps: desktop,
    fileDrop: desktop,
    relaunch: desktop,
    density: desktop ? UiDensity.pointer : UiDensity.touch,
    hostsServer: desktop,
    multicastLock: false,
    mediaPlayback: desktop,
    deviceName: 'test',
    camera: !desktop,
  );

  Future<(ProviderContainer, _FakeHostStatus)> pump(
    WidgetTester tester,
    ServerOverview overview, {
    bool desktop = true,
    Map<String, HostInstallView> machines = const {},
  }) async {
    final size = desktop ? const Size(1440, 900) : const Size(390, 844);
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final status = _FakeHostStatus();
    final server = FakeDataServer();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clientCapabilitiesProvider.overrideWithValue(client(desktop: desktop)),
        localHostSessionAccessProvider.overrideWithValue(null),
        localHostStatusProvider.overrideWith(() => status),
        serverOverviewProvider.overrideWith((ref) async => overview),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        clockProvider.overrideWithValue(FixedClock(now)),
        hostInstallControllerProvider.overrideWith(
          () => _FixedMachines(machines),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ServerStatusSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, status);
  }

  group('desktop', () {
    testWidgets('says it runs, its version beside the app\'s, its uptime, '
        'what it holds and where its data is', (tester) async {
      await pump(tester, running());

      expect(find.text(SettingsAnchor.serverStatus.heading), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Server 1.31.1 · app 1.31.1'), findsOneWidget);
      expect(find.textContaining('differ'), findsNothing);
      expect(find.text('3h 12m'), findsOneWidget);
      expect(find.text('2 running · 5 ended'), findsOneWidget);
      expect(find.text('/data/karmashala'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('the socket path is in a details row', (tester) async {
      await pump(tester, running());

      expect(find.text('/data/karmashala/host.sock'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('/data/karmashala/host.sock'), findsOneWidget);
    });

    testWidgets('warns when the server is not this app\'s version', (
      tester,
    ) async {
      await pump(tester, running(version: '1.30.0'));

      expect(find.text('Server 1.30.0 · app 1.31.1'), findsOneWidget);
      expect(
        find.textContaining('The server and this app differ'),
        findsOneWidget,
      );
    });

    testWidgets('Copy puts the data folder on the clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester, running());

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, ['/data/karmashala']);
    });

    testWidgets('Restart confirms first, naming the live sessions it ends', (
      tester,
    ) async {
      final (_, status) = await pump(tester, running(live: 2));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Restart'));
      await tester.pumpAndSettle();
      expect(find.text('Restart the server?'), findsOneWidget);
      expect(find.textContaining('ends the 2 running sessions'), findsOneWidget);
      expect(find.textContaining('panes keep what they showed'), findsOneWidget);

      await tester.tap(find.text('Restart').last);
      await tester.pumpAndSettle();
      expect(status.calls, ['restart(force: true)']);
    });

    testWidgets('Restart with nothing running still asks, and says nothing '
        'ends', (tester) async {
      final (_, status) = await pump(tester, running(live: 0));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Restart'));
      await tester.pumpAndSettle();
      expect(find.textContaining('runs no sessions'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(status.calls, isEmpty);
    });

    testWidgets('Stop confirms first, naming what it ends and that nothing '
        'starts it again', (tester) async {
      final (_, status) = await pump(tester, running(live: 1));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Stop the server?'), findsOneWidget);
      expect(find.textContaining('ends the 1 running session'), findsOneWidget);
      expect(find.textContaining('until you press Start'), findsOneWidget);

      await tester.tap(find.text('Stop').last);
      await tester.pumpAndSettle();
      expect(status.calls, ['stop(force: true)']);
    });

    testWidgets('a server that would not say what it holds is treated as '
        'holding some', (tester) async {
      await pump(tester, running(live: null, ended: null));

      expect(find.text('Not recorded'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
      await tester.pumpAndSettle();
      expect(find.textContaining('would not say what it holds'), findsOneWidget);
    });

    testWidgets('Restart and Stop are disabled, with the reason, when this '
        'app is not running this machine\'s server', (tester) async {
      await pump(
        tester,
        running(controlsRefusal: 'This window uses a server elsewhere.'),
      );

      final restart = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Restart'),
      );
      final stop = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Stop'),
      );
      expect(restart.onPressed, isNull);
      expect(stop.onPressed, isNull);
      expect(
        find.text('This window uses a server elsewhere.'),
        findsOneWidget,
      );
    });

    testWidgets('the quit switch lives here and keeps its stored value', (
      tester,
    ) async {
      final (container, _) = await pump(tester, running());
      const label = 'Keep sessions running when Karmashala quits';
      expect(find.text(label), findsOneWidget);
      expect(
        container.read(settingsControllerProvider).quitKeepsHostSessions,
        isTrue,
      );

      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsControllerProvider).quitKeepsHostSessions,
        isFalse,
      );
    });

    testWidgets('one row says how many machines run an older server, and '
        'opens Machines', (tester) async {
      final (container, _) = await pump(
        tester,
        running(),
        machines: {
          'a': _view(HostInstallState.outdated),
          'b': _view(HostInstallState.notInstalled),
          'c': _view(HostInstallState.installed),
        },
      );

      expect(
        find.text('1 machine runs an older server · 1 has no server'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open Machines'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsTabSectionProvider)?.anchor,
        SettingsAnchor.sshHosts,
      );
    });

    testWidgets('no such row when every machine read is current', (
      tester,
    ) async {
      await pump(
        tester,
        running(),
        machines: {'c': _view(HostInstallState.installed)},
      );
      expect(find.text('Open Machines'), findsNothing);
    });
  });

  group('phone', () {
    testWidgets('a read-only summary: status, version, sessions held', (
      tester,
    ) async {
      await pump(tester, running(), desktop: false);

      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Server 1.31.1 · app 1.31.1'), findsOneWidget);
      expect(find.text('2 running · 5 ended'), findsOneWidget);
      expect(find.text('Restart'), findsNothing);
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Open'), findsNothing);
      expect(
        find.text('Keep sessions running when Karmashala quits'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  test('uptime reads as hours and minutes, or days and hours', () {
    expect(describeUptime(const Duration(seconds: 40)), 'under a minute');
    expect(describeUptime(const Duration(minutes: 7)), '7m');
    expect(describeUptime(const Duration(hours: 3, minutes: 12)), '3h 12m');
    expect(describeUptime(const Duration(days: 2, hours: 5)), '2d 5h');
  });
}

HostInstallView _view(HostInstallState state) => HostInstallView(
  reading: HostInstallReading(
    state: state,
    observedAt: DateTime.utc(2026, 10, 6),
    reason: state.name,
  ),
);

class _FixedMachines extends HostInstallController {
  _FixedMachines(this.views);

  final Map<String, HostInstallView> views;

  @override
  Map<String, HostInstallView> build() => views;
}

class _FakeHostStatus extends LocalHostStatusController {
  final calls = <String>[];

  @override
  HostDeployment? build() => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> restart({required bool force}) async =>
      calls.add('restart(force: $force)');

  @override
  Future<void> stop({required bool force}) async =>
      calls.add('stop(force: $force)');
}
