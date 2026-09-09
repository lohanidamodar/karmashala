import 'dart:async';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala/src/features/devices/application/ios_device_providers.dart';
import 'package:karmashala/src/features/devices/data/wda_backend.dart';
import 'package:karmashala/src/features/devices/domain/ios_simulator.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/device_input.dart';
import 'package:karmashala/src/features/devices/presentation/device_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

const _emulator = 'emulator-5554';
const _phoneSerial = 'F6IZLV6LMFT4U4ZT';

/// The tooltip every device control wears while nothing is running behind it.
const _idleKeys = 'Start the live view to use the device controls';

AndroidSdk _sdk() => const AndroidSdk(
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

AndroidDevice _device({
  String serial = _emulator,
  DeviceConnectionState state = DeviceConnectionState.device,
  String model = 'Pixel',
}) => AndroidDevice(
  serial: serial,
  environmentId: 'windows',
  state: state,
  model: model,
);

Future<void> _pump(
  WidgetTester tester, {
  required AndroidSdk? sdk,
  required List<AndroidDevice> devices,
  List<Avd> avds = const [],
  Map<String, DeviceScreenSize> screens = const {},
  Size size = _desktop,
  FakeCommandRunner? runner,
  List<IosSimulator> simulators = const [],
  bool simulatorBackend = false,
  List<String> slimmingArguments = const [],

  /// Leaves the probes hanging, which is the state the pane is in for the
  /// ~460ms its first listing takes on a real machine.
  bool stillProbing = false,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (runner != null)
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        androidSdkProvider.overrideWith(
          (ref) => stillProbing
              ? Completer<AndroidSdk?>().future
              : Future.value(sdk),
        ),
        // The emulator argv and the post-boot slimming both come from saved
        // settings, which would drag a database into a widget test. Overridden
        // here so these cases stay about the pane.
        androidEmulatorArgumentsProvider.overrideWithValue(slimmingArguments),
        androidSlimmingServiceProvider.overrideWithValue(null),
        // The iOS side reads the same saved settings, and its "Slim on start"
        // row is now on screen whenever a simulator is booted rather than only
        // when one is startable.
        slimmingOnStartProvider.overrideWithValue(false),
        slimmingKeptCategoriesProvider.overrideWithValue(const {}),
        devicesProvider.overrideWith(
          (ref) => stillProbing
              ? Completer<List<AndroidDevice>>().future
              : Future.value(devices),
        ),
        avdsProvider.overrideWith((ref) async => avds),
        deviceScreenSizeProvider.overrideWith(
          (ref, serial) async => screens[serial],
        ),
        hostCanRunSimulatorsProvider.overrideWithValue(simulators.isNotEmpty),
        iosSimulatorsProvider.overrideWith((ref) async => simulators),
        simulatorBackendProvider.overrideWithValue(
          simulatorBackend ? _StubSimulatorBackend() : null,
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: DevicePane())),
    ),
  );
  // `pumpAndSettle` would wait forever on a probe that never answers.
  await (stillProbing ? tester.pump() : tester.pumpAndSettle());
}

class _StubSimulatorBackend implements WdaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('these cases never start a live view');
}

IosSimulator _bootedSimulator(String udid, String name) => IosSimulator(
  udid: udid,
  name: name,
  state: SimulatorState.booted,
  runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
  deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
  isAvailable: true,
);

void main() {
  test('live player overrides the finite network timeout once at setup', () async {
    final writes = <(String, String)>[];
    await configureDeviceLivePlayer((name, value) async {
      writes.add((name, value));
    });

    // A physical-phone idle/resume probe reached EOF with media_kit's 5s
    // timeout. This must be applied on every player, including reattachments.
    expect(
      writes.where((entry) => entry.$1 == 'network-timeout'),
      [('network-timeout', '0')],
    );
    expect(writes, hasLength(10));
    expect(writes.map((entry) => entry.$1).toSet(), hasLength(10));
  });

  group('while it is still finding out', () {
    testWidgets('says it is looking, rather than inviting a pick', (
      tester,
    ) async {
      await _pump(tester, sdk: null, devices: const [], stillProbing: true);

      // The first listing costs about 460ms on a Mac — an SDK to discover,
      // `adb` and `simctl` to ask. For that whole time the pane asked the user
      // to "pick a device below" from a list that had not arrived, which reads
      // as "there is nothing here" right up until it is wrong.
      expect(find.textContaining('Looking for devices'), findsOneWidget);
      expect(find.textContaining('Pick a device below'), findsNothing);
    });

    testWidgets('and stops saying it once the answer is in', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: const []);

      expect(find.textContaining('Looking for devices'), findsNothing);
    });
  });

  group('the device picker', () {
    testWidgets('lists Android devices and booted simulators together', (
      tester,
    ) async {
      // They are one thing to the user: a device with a screen to look at.
      // Listed apart, a booted simulator was absent from the very picker that
      // names what the pane is showing, which read as the app not seeing it.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(serial: 'emulator-5554')],
        simulators: [_bootedSimulator('UDID-1', 'iPhone 17')],
        simulatorBackend: true,
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      expect(find.textContaining('emulator-5554'), findsWidgets);
      expect(find.textContaining('iPhone 17'), findsWidgets);
    });

    testWidgets('picking a simulator offers its live view', (tester) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        simulators: [_bootedSimulator('UDID-1', 'iPhone 17')],
        simulatorBackend: true,
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('iPhone 17').last);
      await tester.pumpAndSettle();

      final button = tester.widget<TextButton>(
        find
            .ancestor(
              of: find.text('Live view'),
              matching: find.byType(TextButton),
            )
            .first,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'a picked simulator is one the pane can mirror',
      );
    });

    testWidgets('a booted simulator is listed under Connected', (tester) async {
      // It was listed in its own section *below* the idle emulators, which put
      // the one device actually running underneath the ones that are not.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        simulators: [_bootedSimulator('booted', 'iPhone 17 Pro')],
        simulatorBackend: true,
      );

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('iPhone 17 Pro'), findsWidgets);
      expect(find.byKey(const Key('stop-simulator-booted')), findsOneWidget);
      expect(find.byKey(const Key('live-view-booted')), findsOneWidget);

      // And the heading starts where its own rows start. It inherited the
      // pane's centred column while every row under it was inset 16, so a
      // one-device list read as a caption floating over a left-aligned list.
      expect(
        tester.getRect(find.text('Connected')).left,
        tester.getRect(find.text('iPhone 17 Pro').first).left,
        reason: 'the heading is aligned with the device under it',
      );
    });

    testWidgets('a simulator row offers no live view without a backend', (
      tester,
    ) async {
      // Without WebDriverAgent it can still be stopped; a Live view button that
      // always failed would be worse than none.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        simulators: [_bootedSimulator('booted', 'iPhone 17 Pro')],
      );

      expect(find.byKey(const Key('stop-simulator-booted')), findsOneWidget);
      expect(find.byKey(const Key('live-view-booted')), findsNothing);
    });

    testWidgets('without a backend the live view is not offered', (
      tester,
    ) async {
      // A button that always failed would be worse than none: WebDriverAgent is
      // what makes the picture possible, and a build without it can still start
      // and stop simulators perfectly well.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        simulators: [_bootedSimulator('UDID-1', 'iPhone 17')],
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('iPhone 17').last);
      await tester.pumpAndSettle();

      final button = tester.widget<TextButton>(
        find
            .ancestor(
              of: find.text('Live view'),
              matching: find.byType(TextButton),
            )
            .first,
      );
      expect(button.onPressed, isNull);
    });
  });

  group('DevicePane empty states', () {
    testWidgets('explains how to install the SDK when none is found', (
      tester,
    ) async {
      await _pump(tester, sdk: null, devices: const []);
      expect(find.textContaining('No Android SDK found'), findsOneWidget);
      expect(find.textContaining('ANDROID_HOME'), findsOneWidget);
    });

    testWidgets('asks for a device when the SDK is present but nothing is '
        'connected', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: const []);
      expect(find.textContaining('No devices connected'), findsOneWidget);
    });

    testWidgets('surfaces an unauthorized device instead of hiding it', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(state: DeviceConnectionState.unauthorized)],
      );
      // Twice over: the pane says why it is empty, and the row says what is
      // wrong with that particular device.
      expect(
        find.textContaining('accept the USB debugging prompt'),
        findsWidgets,
      );
    });

    testWidgets('offers to boot an AVD when one exists', (tester) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
      );
      expect(find.text('Pixel_8_Pro'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('points at the list once a device is ready', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.textContaining('Pick a device below'), findsOneWidget);
      expect(find.text('Live view'), findsOneWidget);
    });
  });

  group('DevicePane layout', () {
    testWidgets('renders without overflow at a compact size', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()], size: _phone);
      expect(tester.takeException(), isNull);
      expect(find.byType(DevicePane), findsOneWidget);
    });

    testWidgets('renders without overflow at a desktop size', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()], size: _desktop);
      expect(tester.takeException(), isNull);
      expect(find.byType(DevicePane), findsOneWidget);
    });

    testWidgets('the emulator list does not overflow a compact pane', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [
          Avd(name: 'Pixel_8_Pro', runningSerial: _emulator),
          Avd(name: 'Pixel_Tablet'),
          Avd(name: 'Nexus_5'),
          Avd(name: 'Wear_Small'),
        ],
        size: _phone,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('hides the hardware buttons when no device is selected', (
      tester,
    ) async {
      await _pump(tester, sdk: _sdk(), devices: const []);
      expect(find.byTooltip('Back'), findsNothing);
      expect(find.byTooltip(_idleKeys), findsNothing);
    });

    testWidgets('the device controls cannot reach a device with no live view', (
      tester,
    ) async {
      final runner = FakeCommandRunner();
      await _pump(tester, sdk: _sdk(), devices: [_device()], runner: runner);

      // Present — so the row does not appear from nowhere when the live view
      // starts — but inert, and saying so. Six of them now: the three hardware
      // keys, plus the appearance switch, the screenshot and the deep link
      // that Android gained to match what the simulator row already offered.
      final idle = find.byTooltip(_idleKeys);
      expect(idle, findsNWidgets(6));
      for (final button in tester.widgetList<IconButton>(
        find.descendant(of: idle, matching: find.byType(IconButton)),
      )) {
        expect(button.onPressed, isNull);
      }

      // The real assertion: nothing reaches the phone. This is the bug —
      // stopping the live view left Home and Back driving the device the user
      // believed they had disconnected from. Now that the row can also take a
      // screenshot and open a deep link, *no* adb command may leave it.
      for (var i = 0; i < 6; i++) {
        await tester.tap(idle.at(i), warnIfMissed: false);
      }
      await tester.pumpAndSettle();
      expect(runner.requests, isEmpty);
    });
  });

  group('deviceUnavailableReason', () {
    test('says nothing while discovery is still running', () {
      expect(
        deviceUnavailableReason(
          sdk: null,
          sdkResolved: false,
          devices: const [],
          kind: EnvironmentKind.windowsNative,
        ),
        isNull,
      );
    });

    test('names the WSL location when the environment is WSL', () {
      final reason = deviceUnavailableReason(
        sdk: null,
        sdkResolved: true,
        devices: const [],
        kind: EnvironmentKind.wsl,
      );
      expect(reason, contains('~/Android/Sdk'));
    });

    test('is null once a ready device exists', () {
      expect(
        deviceUnavailableReason(
          sdk: _sdk(),
          sdkResolved: true,
          devices: [_device()],
          kind: EnvironmentKind.windowsNative,
        ),
        isNull,
      );
    });

    test('reports offline devices distinctly from unauthorized ones', () {
      final reason = deviceUnavailableReason(
        sdk: _sdk(),
        sdkResolved: true,
        devices: [_device(state: DeviceConnectionState.offline)],
        kind: EnvironmentKind.windowsNative,
      );
      expect(reason, contains('offline'));
    });
  });

  group('DevicePane toolbar', () {
    testWidgets('the device picker is sized like the chrome around it', (
      tester,
    ) async {
      // `DropdownButton` is Material 2 and ignores the app's
      // `dropdownMenuTheme`, which only reaches Material 3's `DropdownMenu`.
      // Left alone it renders at Material's ~16 px with a 24 px chevron beside
      // a pane built from `bodySmall` and `Chrome.icon` — which is what made a
      // device name wrap onto two lines.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(serial: _phoneSerial, model: 'CPH1989')],
      );
      final picker = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      final theme = Theme.of(
        tester.element(find.byType(DropdownButton<String>)),
      );
      expect(picker.style, theme.textTheme.bodySmall);
      expect(picker.iconSize, Chrome.icon);
      expect(picker.isDense, isTrue);
    });

    testWidgets('a long device name ellipsizes rather than wrapping', (
      tester,
    ) async {
      // "CPH1989 (F6IZLV6LMFT4U4ZT)" is a name plus a serial, and the serial
      // stays: it is what tells two identical handsets apart in the picker
      // itself. One line is the contract; the pane can be narrow.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(serial: _phoneSerial, model: 'CPH1989')],
        size: _phone,
      );
      final label = tester.widget<Text>(
        find.text('CPH1989 ($_phoneSerial)').first,
      );
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
    });

    testWidgets('the refresh button says what it actually refreshes', (
      tester,
    ) async {
      // It used to say "Refresh devices", so that is what people pressed when
      // the live view froze — and it refreshed the list, not the stream.
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.byTooltip('Refresh device list'), findsOneWidget);
      expect(find.byTooltip('Refresh devices'), findsNothing);
    });

    testWidgets('offers wireless pairing beside the refresh, with an SDK', (
      tester,
    ) async {
      // On the toolbar rather than in a section header: the toolbar is on
      // screen whatever the pane is showing, so it is reachable from the empty
      // state a user with no cable actually sees.
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(
        find.byKey(const Key('wireless-pairing-open')),
        findsOneWidget,
      );
      expect(find.byTooltip('Pair a device over Wi-Fi'), findsOneWidget);
    });

    testWidgets('and does not offer it when there is no adb to pair with', (
      tester,
    ) async {
      await _pump(tester, sdk: null, devices: const []);
      expect(find.byKey(const Key('wireless-pairing-open')), findsNothing);
    });

    testWidgets('the empty state points at wireless pairing too', (
      tester,
    ) async {
      await _pump(tester, sdk: _sdk(), devices: const []);
      expect(find.textContaining('pair one over Wi-Fi'), findsOneWidget);
    });

    testWidgets('offers to stop a selected emulator', (tester) async {
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      // The tooltip names the device now, because the button used to be able
      // to stop one the user was not looking at.
      expect(find.byTooltip('Stop Pixel'), findsOneWidget);
    });

    testWidgets('does not offer to stop a physical device', (tester) async {
      // `emu kill` talks to the emulator console; on a phone it can only fail,
      // and a control that can only fail should not be there.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(serial: _phoneSerial)],
      );
      expect(find.byTooltip('Stop Pixel'), findsNothing);
      expect(
        find.byKey(const Key('stop-emulator-$_phoneSerial')),
        findsNothing,
      );
    });

    testWidgets(
      'stopping an emulator asks first, and cancelling does nothing',
      (tester) async {
        final runner = FakeCommandRunner();
        await _pump(tester, sdk: _sdk(), devices: [_device()], runner: runner);
        await tester.tap(find.byTooltip('Stop Pixel'));
        await tester.pumpAndSettle();
        expect(find.textContaining('is lost'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(
          runner.requests.any((r) => r.arguments.contains('kill')),
          isFalse,
        );
      },
    );
  });

  // Bug 1: "i see an emulator running but cannot stop it in the list without
  // starting live view". The action existed, but only on the live-view toolbar.
  group('DevicePane device list', () {
    testWidgets('offers to stop a running emulator with the live view off', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
      );
      // Nothing is streaming — the toolbar still offers to *start* the live
      // view — and the row is stoppable anyway. That is the whole fix.
      expect(find.text('Live view'), findsOneWidget);
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsOneWidget);
      expect(find.text('Start'), findsNothing);
    });

    testWidgets('stopping from the list confirms, then runs emu kill', (
      tester,
    ) async {
      final runner = FakeCommandRunner();
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('stop-emulator-$_emulator')));
      await tester.pumpAndSettle();
      // The confirmation is kept: anything not written to a snapshot is lost.
      expect(find.textContaining('is lost'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Stop emulator'));
      await tester.pumpAndSettle();

      expect(
        runner.requests.map((r) => r.arguments.join(' ')),
        contains('-s $_emulator emu kill'),
      );
    });

    testWidgets('cancelling a stop from the list kills nothing', (
      tester,
    ) async {
      final runner = FakeCommandRunner();
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('stop-emulator-$_emulator')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(runner.requests.any((r) => r.arguments.contains('kill')), isFalse);
    });

    testWidgets('an AVD that is not running offers Start, not Stop', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
      );
      expect(find.byKey(const Key('start-avd-Pixel_8_Pro')), findsOneWidget);
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsNothing);
    });

    testWidgets('a running emulator with no AVD row is still stoppable', (
      tester,
    ) async {
      // No emulator package means no AVD list at all, but `adb devices` still
      // shows the emulator and `emu kill` still works on it.
      await _pump(tester, sdk: _sdk(), devices: [_device()]);
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsOneWidget);
    });

    testWidgets('a running emulator is not listed twice', (tester) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
      );
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsOneWidget);
    });

    testWidgets('a physical device is listed, with a preview and no stop', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device(serial: _phoneSerial, model: 'CPH1989')],
      );
      expect(find.text('CPH1989'), findsOneWidget);
      expect(find.byKey(const Key('preview-$_phoneSerial')), findsOneWidget);
      expect(
        find.byKey(const Key('stop-emulator-$_phoneSerial')),
        findsNothing,
      );
    });

    testWidgets('a running emulator offers both a preview and a stop', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
      );
      expect(find.byKey(const Key('preview-$_emulator')), findsOneWidget);
      expect(find.byKey(const Key('stop-emulator-$_emulator')), findsOneWidget);
      // Named by its AVD, which is what the user called it.
      expect(find.text('Pixel_8_Pro'), findsOneWidget);
    });

    testWidgets('an unauthorized device says what to do about it and offers '
        'nothing', (tester) async {
      // A row that can only fail should not have a button on it.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [
          _device(
            serial: _phoneSerial,
            model: 'CPH1989',
            state: DeviceConnectionState.unauthorized,
          ),
        ],
      );
      expect(find.text('CPH1989'), findsOneWidget);
      expect(
        find.textContaining('accept the USB debugging prompt'),
        findsWidgets,
      );
      expect(find.byKey(const Key('preview-$_phoneSerial')), findsNothing);
    });

    testWidgets('an offline device is shown and explained, not hidden', (
      tester,
    ) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [
          _device(
            serial: _phoneSerial,
            model: 'CPH1989',
            state: DeviceConnectionState.offline,
          ),
        ],
      );
      expect(find.textContaining('offline —'), findsOneWidget);
      expect(find.byKey(const Key('preview-$_phoneSerial')), findsNothing);
    });
  });

  // The owner: "previously, sambandha test was running in background without
  // ui and we could connect using live preview; that would be the best
  // approach, like Android Studio does."
  group('DevicePane emulator boot', () {
    /// A runner that plays a whole emulator boot: the device appears, says
    /// which AVD it is, and reports `sys.boot_completed` after [slowPolls]
    /// polls that answer "not yet".
    FakeCommandRunner bootingRunner({int slowPolls = 0}) {
      var polls = 0;
      return FakeCommandRunner(
        responder: (request) {
          final args = request.arguments.join(' ');
          if (args == 'devices -l') {
            return const CommandResult(
              exitCode: 0,
              stdout:
                  'List of devices attached\n'
                  '$_emulator  device product:sdk model:Pixel transport_id:2\n',
              stderr: '',
            );
          }
          if (args.endsWith('emu avd name')) {
            return const CommandResult(
              exitCode: 0,
              stdout: 'Pixel_8_Pro\nOK\n',
              stderr: '',
            );
          }
          if (args.contains('sys.boot_completed')) {
            polls += 1;
            return CommandResult(
              exitCode: 0,
              stdout: polls > slowPolls ? '1\n' : '0\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
    }

    Future<void> settle(WidgetTester tester, {int frames = 12}) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('offers headless boot, and defaults to it', (tester) async {
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
      );
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('headless-emulator-toggle')),
      );
      expect(toggle.value, isTrue);
    });

    testWidgets('starting an AVD boots it without a window', (tester) async {
      final runner = bootingRunner();
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('start-avd-Pixel_8_Pro')));
      await settle(tester);
      expect(runner.startRequests.single.arguments, [
        '-avd',
        'Pixel_8_Pro',
        '-no-window',
        '-no-boot-anim',
      ]);
    });

    testWidgets('the slimming flags reach the emulator', (tester) async {
      final runner = bootingRunner();
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
        runner: runner,
        slimmingArguments: const ['-no-audio', '-gpu', 'host'],
      );
      await tester.tap(find.byKey(const Key('start-avd-Pixel_8_Pro')));
      await settle(tester);
      expect(runner.startRequests.single.arguments, [
        '-avd',
        'Pixel_8_Pro',
        '-no-window',
        '-no-boot-anim',
        '-no-audio',
        '-gpu',
        'host',
      ]);
    });

    testWidgets('Slimming stays reachable when every emulator is running', (
      tester,
    ) async {
      // The button hung off the *idle* list, so the one machine-with-one-AVD
      // case took the dialog away the moment that AVD started — and with it
      // Restore, which only works on a running emulator and is the escape
      // hatch for one whose Play services are disabled.
      await _pump(
        tester,
        sdk: _sdk(),
        devices: [_device()],
        avds: const [Avd(name: 'Pixel_8_Pro', runningSerial: _emulator)],
      );

      expect(find.byKey(const Key('android-slimming-open')), findsOneWidget);
      expect(
        find.byKey(const Key('start-avd-Pixel_8_Pro')),
        findsNothing,
        reason: 'it is running, so there is nothing to start',
      );
      expect(find.textContaining('Every emulator is running'), findsOneWidget);
    });

    testWidgets('the toggle really controls the window', (tester) async {
      // The extended controls — rotation, location, simulated calls — only
      // exist in the emulator's own window, so this has to be reachable.
      final runner = bootingRunner();
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('headless-emulator-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-avd-Pixel_8_Pro')));
      await settle(tester);
      expect(
        runner.startRequests.single.arguments,
        isNot(contains('-no-window')),
      );
    });

    testWidgets('a booting row says so rather than looking ignored', (
      tester,
    ) async {
      // Headless there is nothing on screen to show for the click at all.
      final runner = bootingRunner(slowPolls: 1);
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('start-avd-Pixel_8_Pro')));
      await tester.pump();
      await tester.pump();
      expect(find.text('starting…'), findsOneWidget);
      expect(find.text('Start'), findsNothing);

      await settle(tester, frames: 40);
      expect(find.text('starting…'), findsNothing);
    });

    testWidgets('a boot that fails is reported, and the row resets', (
      tester,
    ) async {
      // Headless, a failed boot is completely invisible otherwise: no window
      // appears either way. (The three-minute timeout itself is covered in
      // adb_service_test — it is wall-clock bounded, which a fake test clock
      // cannot advance.)
      final runner = FakeCommandRunner(
        throwError: StateError('emulator.exe could not be started'),
      );
      await _pump(
        tester,
        sdk: _sdk(),
        devices: const [],
        avds: const [Avd(name: 'Pixel_8_Pro')],
        runner: runner,
      );
      await tester.tap(find.byKey(const Key('start-avd-Pixel_8_Pro')));
      await settle(tester);
      expect(find.textContaining('could not be started'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget, reason: 'the row must reset');
      await tester.pump(const Duration(seconds: 6));
    });
  });

  // Bug 2: "on live view when i switch to another device, live view still
  // showing old device". `_streamingSerial` won once streaming started and
  // nothing watched the selection, so the picture stayed put.
  group('liveViewSelection', () {
    final emulator = _device();
    final phone = _device(serial: _phoneSerial, model: 'CPH1989');
    final offline = _device(
      serial: 'offline-1',
      state: DeviceConnectionState.offline,
    );
    final devices = [emulator, phone, offline];

    test('does nothing while the live view is off', () {
      // Picking a device in the toolbar is not a request to start streaming it.
      final next = liveViewSelection(
        liveSerial: null,
        selectedSerial: _phoneSerial,
        devices: devices,
      );
      expect(next.action, LiveViewSelectionAction.none);
    });

    test('does nothing when the choice is already the device on screen', () {
      final next = liveViewSelection(
        liveSerial: _emulator,
        selectedSerial: _emulator,
        devices: devices,
      );
      expect(next.action, LiveViewSelectionAction.none);
    });

    test('moves the live view to the newly chosen device', () {
      final next = liveViewSelection(
        liveSerial: _emulator,
        selectedSerial: _phoneSerial,
        devices: devices,
      );
      expect(next.action, LiveViewSelectionAction.moveTo);
      expect(next.device, phone);
    });

    test('stops the live view when the choice is cleared', () {
      final next = liveViewSelection(
        liveSerial: _emulator,
        selectedSerial: null,
        devices: devices,
      );
      expect(next.action, LiveViewSelectionAction.stop);
    });

    test('stops rather than leave a stale picture up when the chosen device '
        'is not ready', () {
      final next = liveViewSelection(
        liveSerial: _emulator,
        selectedSerial: 'offline-1',
        devices: devices,
      );
      expect(next.action, LiveViewSelectionAction.stop);
      expect(next.device, isNull);
    });

    test('stops when the chosen device is not in the list at all', () {
      final next = liveViewSelection(
        liveSerial: _emulator,
        selectedSerial: 'ghost',
        devices: devices,
      );
      expect(next.action, LiveViewSelectionAction.stop);
    });
  });

  // Bug 3: the adb gesture sink took its coordinate space from the *selected*
  // device's screen size. Once selection and streaming diverged, a tap was
  // mapped through the wrong resolution and landed in the wrong place on the
  // device being watched — while appearing to work.
  group('deviceScreenSizeProvider', () {
    ProviderContainer containerFor(FakeCommandRunner runner) {
      final container = ProviderContainer(
        overrides: [
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
          androidSdkProvider.overrideWith((ref) async => _sdk()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('reports each device its own screen size, by serial', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          final args = request.arguments.join(' ');
          if (args == '-s $_emulator shell wm size') {
            return const CommandResult(
              exitCode: 0,
              stdout: 'Physical size: 1080x2400\n',
              stderr: '',
            );
          }
          if (args == '-s $_phoneSerial shell wm size') {
            return const CommandResult(
              exitCode: 0,
              stdout: 'Physical size: 1080x2340\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );
      final container = containerFor(runner);
      await container.read(androidSdkProvider.future);

      // The two devices differ by 60 px of height. Asking for one and being
      // given the other's is exactly how a tap lands in the wrong place.
      expect(
        await container.read(deviceScreenSizeProvider(_emulator).future),
        const DeviceScreenSize(width: 1080, height: 2400),
      );
      expect(
        await container.read(deviceScreenSizeProvider(_phoneSerial).future),
        const DeviceScreenSize(width: 1080, height: 2340),
      );
    });

    test('asks the device named, and no other', () async {
      final runner = FakeCommandRunner();
      final container = containerFor(runner);
      await container.read(androidSdkProvider.future);
      await container.read(deviceScreenSizeProvider(_phoneSerial).future);

      expect(runner.requests.map((r) => r.arguments.join(' ')), [
        '-s $_phoneSerial shell wm size',
      ]);
    });

    test('is null when there is no SDK to ask with', () async {
      final container = ProviderContainer(
        overrides: [androidSdkProvider.overrideWith((ref) async => null)],
      );
      addTearDown(container.dispose);
      await container.read(androidSdkProvider.future);
      expect(
        await container.read(deviceScreenSizeProvider(_emulator).future),
        isNull,
      );
    });
  });
}
