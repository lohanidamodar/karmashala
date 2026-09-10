import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/file_picking.dart';
import 'package:karmashala/src/features/devices/application/device_claims.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/devices/presentation/device_app_controls.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import 'device_claims_test.dart' show MovableClock;

const _serial = 'emulator-5554';

const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
  emulator: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\emulator\emulator.exe',
  ),
);

const _device = AndroidDevice(
  serial: _serial,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'Pixel',
);

/// **Install, launch and force-stop, from the window.**
///
/// The finding this closes: an agent could put a build on the device and
/// cold-restart it, and the person watching the live view could not — so a
/// manual test had to leave the app to do the one thing it is for.
///
/// Nothing here touches a device: `AdbService` is real over a fake
/// `CommandRunner`, which is how every adb test in this suite works.
void main() {
  late FakeCommandRunner runner;
  late MovableClock clock;

  /// How many times the widget reached for the host's dialog. The typed-path
  /// tests are about this being zero.
  var picks = 0;

  setUp(() {
    picks = 0;
    clock = MovableClock(testTime);
    runner = FakeCommandRunner(
      responder: (request) => request.arguments.contains('devices')
          ? const CommandResult(
              exitCode: 0,
              stdout: 'List of devices attached\n'
                  '$_serial\tdevice product:sdk model:Pixel device:emu\n',
              stderr: '',
            )
          : const CommandResult(exitCode: 0, stdout: 'Success\n', stderr: ''),
    );
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    DeviceClaims? claims,
    XFile? picked,
  }) async {
    final container = ProviderContainer(
      overrides: [
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
        androidSdkProvider.overrideWith((ref) async => _sdk),
        adbServiceProvider.overrideWithValue(
          AdbService(runner: runner, sdk: _sdk),
        ),
        devicesProvider.overrideWith((ref) async => const [_device]),
        clockProvider.overrideWithValue(clock),
        if (claims != null) deviceClaimsProvider.overrideWithValue(claims),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DeviceAppControls(
              device: _device,
              // Never the host's dialog: on Windows it runs on this isolate's
              // own thread, so a test that reached it would hang the run.
              pickFile: () async {
                picks += 1;
                return picked;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// The button behind a tooltip — `find.byTooltip` lands on the tooltip
  /// itself, not the control wearing it.
  IconButton iconButton(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      );

  /// The argv of the last adb call, or null when nothing was run.
  List<String>? lastArgv() =>
      runner.requests.isEmpty ? null : runner.requests.last.arguments;

  testWidgets('installing sends the picked build to this device', (
    tester,
  ) async {
    await pump(tester, picked: XFile(r'C:\builds\app-debug.apk'));

    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();

    expect(lastArgv(), [
      '-s',
      _serial,
      'install',
      '-r',
      '-t',
      r'C:\builds\app-debug.apk',
    ]);
    // §19: the answer is a reading, and it carries when the driver said it.
    expect(find.textContaining('just now'), findsOneWidget);
  });

  testWidgets('a typed path installs, and no dialog is opened', (
    tester,
  ) async {
    // The rule `core/util/file_picking.dart` states: every Browse surface also
    // accepts a typed path, because on Windows a picker that never appears
    // leaves nothing to press. This was the last surface without one.
    await pump(tester);

    await tester.enterText(
      find.byKey(const Key('device-install-path')),
      r'C:\builds\app-release.apk',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(lastArgv(), [
      '-s',
      _serial,
      'install',
      '-r',
      '-t',
      r'C:\builds\app-release.apk',
    ]);
    expect(picks, 0, reason: 'a typed path must not open the host dialog');
  });

  testWidgets('the label keeps its ellipsis only while a dialog is coming', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Install…'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('device-install-path')),
      r'C:\builds\app.apk',
    );
    await tester.pumpAndSettle();

    expect(find.text('Install…'), findsNothing);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets("Explorer's quoted path installs as typed", (tester) async {
    await pump(tester);

    // What **Copy as path** puts on the clipboard, verbatim.
    await tester.enterText(
      find.byKey(const Key('device-install-path')),
      '"C:\\builds\\app.apk"',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(lastArgv()?.last, r'C:\builds\app.apk');
    expect(picks, 0);
  });

  testWidgets('Enter in the path field installs it', (tester) async {
    await pump(tester);

    await tester.enterText(
      find.byKey(const Key('device-install-path')),
      r'C:\builds\app.apk',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(lastArgv(), contains('install'));
    expect(picks, 0);
  });

  testWidgets('a dismissed picker installs nothing', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();

    expect(runner.requests, isEmpty);
  });

  testWidgets('launch and force-stop act on the typed applicationId', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(
      find.byKey(const Key('device-app-id')),
      'com.example.app',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Launch this app'));
    await tester.pumpAndSettle();
    expect(lastArgv(), contains('monkey'));
    expect(lastArgv(), contains('com.example.app'));

    await tester.tap(find.byTooltip('Force-stop this app'));
    await tester.pumpAndSettle();
    expect(lastArgv(), [
      '-s',
      _serial,
      'shell',
      'am',
      'force-stop',
      'com.example.app',
    ]);
  });

  testWidgets('with no applicationId there is nothing to launch or stop', (
    tester,
  ) async {
    await pump(tester);

    // Disabled rather than absent: a control that vanishes reads as a fault,
    // an inert one says what it is waiting for.
    expect(iconButton(tester, 'Launch this app').onPressed, isNull);
    expect(iconButton(tester, 'Force-stop this app').onPressed, isNull);
  });

  testWidgets('a device another session is driving is refused, by holder', (
    tester,
  ) async {
    final claims = DeviceClaims(
      clock: clock,
      holder: (sessionId) => 'the emulator run',
    );
    // Another session took the device first, exactly as `_driverToDrive` does.
    claims.claim(
      deviceId: _serial,
      sessionId: 'other-session',
      verb: 'device_tap',
    );
    await pump(tester, claims: claims, picked: XFile(r'C:\builds\app.apk'));

    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('being driven by another agent'), findsOneWidget);
    expect(find.textContaining('the emulator run'), findsOneWidget);
    // And it did not act anyway: refusing has to mean the device was untouched.
    expect(
      runner.requests.any((r) => r.arguments.contains('install')),
      isFalse,
    );
  });

  testWidgets('the window respects a claim but never takes one', (
    tester,
  ) async {
    final claims = DeviceClaims(clock: clock, holder: (_) => 'a session');
    await pump(tester, claims: claims, picked: XFile(r'C:\builds\app.apk'));

    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();

    // A person is at the machine; a claim in their name would have no holder to
    // name and no end. `DeviceClaims` already treats a null session that way.
    expect(claims.standingClaims, isEmpty);
    expect(claims.standing(_serial), isNull);
  });
}
