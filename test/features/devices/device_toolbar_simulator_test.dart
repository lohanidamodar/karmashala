import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala/src/features/devices/application/ios_device_providers.dart';
import 'package:karmashala/src/features/devices/application/simulator_frames.dart';
import 'package:karmashala/src/features/devices/application/simulator_live_view.dart';
import 'package:karmashala/src/features/devices/data/wda_backend.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/ios_simulator.dart';
import 'package:karmashala/src/features/devices/domain/simulator_backend.dart';
import 'package:karmashala/src/features/devices/presentation/device_pane.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';

/// The toolbar beside the device picker, while a simulator's picture is up.
///
/// Every case here has **one ready Android device attached**, because that is
/// what made the reported fault possible and it is the ordinary state of a Mac
/// with a phone plugged in or an emulator running. `selectedDeviceProvider`
/// answers "the only ready device" when nobody has chosen anything, so the
/// toolbar's old `selected == null` guard was never true there — it read the
/// pane as being about the phone while the screen showed an iPhone, and every
/// control was wired accordingly.
const _udid = 'UDID-1';
const _serial = 'emulator-5554';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'mac', path: '/sdk'),
  adb: EnvironmentPath(environmentId: 'mac', path: '/sdk/platform-tools/adb'),
  emulator: EnvironmentPath(
    environmentId: 'mac',
    path: '/sdk/emulator/emulator',
  ),
);

AndroidDevice _device() => const AndroidDevice(
  serial: _serial,
  environmentId: 'mac',
  state: DeviceConnectionState.device,
  model: 'Pixel',
);

IosSimulator _booted() => const IosSimulator(
  udid: _udid,
  name: 'iPhone 17',
  state: SimulatorState.booted,
  runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
  deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
  isAvailable: true,
);

/// Never reached: no case here starts a real live view.
class _StubBackend implements WdaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('these cases never talk to WebDriverAgent');
}

/// A live view that is already up, counting what the toolbar asks of it.
///
/// The real controller cannot be driven here — starting it needs
/// WebDriverAgent inside a booted simulator and an MJPEG socket to read — so
/// the states it can be in are supplied directly and the two calls the toolbar
/// can make are recorded.
class _FakeLiveView extends SimulatorLiveViewController {
  _FakeLiveView(this._initial);

  final SimulatorLiveViewState _initial;
  int stops = 0;
  final List<String> starts = [];

  @override
  SimulatorLiveViewState build() => _initial;

  @override
  Future<void> stop() async {
    stops++;
    state = const SimulatorLiveViewIdle();
  }

  @override
  Future<void> start(String udid) async {
    starts.add(udid);
    state = _initial;
  }
}

/// A simulator selection that is already made, the way `start` leaves it.
class _PickedSimulator extends SelectedSimulatorUdid {
  _PickedSimulator(this._initial);
  final String? _initial;
  @override
  String? build() => _initial;
}

SimulatorLiveViewState _running() => SimulatorLiveViewRunning(
  SimulatorLiveView(
    udid: _udid,
    // No frames will ever arrive; the pane paints black until one does, which
    // is all this needs — the toolbar is what is under test.
    frames: SimulatorFrames(const Stream<Uint8List>.empty()),
    feed: SimulatorVideoFeed(
      url: Uri.parse('http://127.0.0.1:9100/'),
      stop: () async {},
    ),
  ),
);

void main() {
  Future<_FakeLiveView> pump(
    WidgetTester tester, {
    required SimulatorLiveViewState live,
    List<AndroidDevice> devices = const [],
    String? picked = _udid,
    // A live view that is *starting* draws a spinner that never stops, so
    // `pumpAndSettle` would sit there until it timed out.
    bool settle = true,
  }) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = _FakeLiveView(live);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          androidSdkProvider.overrideWith((ref) async => _sdk()),
          devicesProvider.overrideWith((ref) async => devices),
          avdsProvider.overrideWith((ref) async => const <Avd>[]),
          deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
          hostCanRunSimulatorsProvider.overrideWithValue(true),
          iosSimulatorsProvider.overrideWith((ref) async => [_booted()]),
          simulatorBackendProvider.overrideWithValue(_StubBackend()),
          selectedSimulatorUdidProvider.overrideWith(
            () => _PickedSimulator(picked),
          ),
          simulatorLiveViewProvider.overrideWith(() => fake),
        ],
        child: const MaterialApp(home: Scaffold(body: DevicePane())),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return fake;
  }

  group('the Stop beside the picker', () {
    testWidgets('stops the simulator whose picture is up, with a phone '
        'attached', (tester) async {
      // The reported fault, exactly. The toolbar offered *Live view* here —
      // Android's — while an iPhone filled the pane; pressing it started a
      // scrcpy stream, after which the button did say Stop and stopped that
      // stream instead, leaving the simulator's picture where it was.
      final fake = await pump(
        tester,
        live: _running(),
        devices: [_device()],
      );

      expect(
        find.text('Live view'),
        findsNothing,
        reason: 'nothing is waiting to be started: a picture is already up',
      );

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();

      expect(fake.stops, 1);
    });

    testWidgets('stops a live view that is still starting, and offers no '
        'restart while it does', (tester) async {
      // Twenty seconds of WebDriverAgent bootstrap is the longest anyone waits
      // in this pane, and it is when they are most likely to change their mind.
      //
      // Restart is deliberately absent for that whole window:
      // `SimulatorLiveViewController.start` refuses to interrupt a start
      // already in flight, so the button would do nothing at exactly the
      // moment somebody reached for it. Stop is what works, and Stop is what
      // is offered.
      final fake = await pump(
        tester,
        live: const SimulatorLiveViewStarting(_udid),
        devices: [_device()],
        settle: false,
      );

      expect(find.byTooltip('Restart live view'), findsNothing);
      await tester.tap(find.text('Stop'));
      await tester.pump();

      expect(fake.stops, 1);
    });

    testWidgets('names the simulator in the picker, not the only phone', (
      tester,
    ) async {
      final fake = await pump(tester, live: _running(), devices: [_device()]);

      expect(
        tester.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>),
        ).value,
        'simulator:$_udid',
        reason: 'the picker names what the pane is showing',
      );
      expect(fake.stops, 0);
    });

    testWidgets('a simulator picked with a phone attached is the one started', (
      tester,
    ) async {
      // Before the live view exists at all: picking the iPhone here used to
      // snap the picker straight back to the phone, so Live view started the
      // phone's stream and the simulator was unreachable from this toolbar.
      final fake = await pump(
        tester,
        live: const SimulatorLiveViewIdle(),
        devices: [_device()],
      );

      // The toolbar's, not the simulator row's further down the pane.
      await tester.tap(find.text('Live view').first);
      await tester.pumpAndSettle();

      expect(fake.starts, [_udid]);
    });

    testWidgets('picking the phone takes the simulator picture down', (
      tester,
    ) async {
      // Deselecting the simulator is not enough: the pane shows that picture
      // ahead of every Android branch, so it would stay on screen with the
      // picker naming a device that is not in it.
      final fake = await pump(
        tester,
        live: _running(),
        devices: [_device()],
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(_serial).last);
      await tester.pumpAndSettle();

      expect(fake.stops, 1);
    });
  });

  group('Restart live view', () {
    testWidgets('is offered for a running simulator, and restarts it', (
      tester,
    ) async {
      // It used to be Android's alone — `onRestart` is supplied only by the
      // Android path — so a stalled simulator picture could only be recovered
      // by Stop followed by Live view, on the platform where starting again
      // costs twenty seconds.
      final fake = await pump(
        tester,
        live: _running(),
        devices: [_device()],
      );

      await tester.tap(find.byTooltip('Restart live view'));
      await tester.pumpAndSettle();

      expect(fake.starts, [_udid]);
      expect(fake.stops, 0, reason: 'start tears the old view down itself');
    });

    testWidgets('is offered for a failed one, which is the retry', (
      tester,
    ) async {
      final fake = await pump(
        tester,
        live: const SimulatorLiveViewFailed(_udid, 'no runner'),
        devices: [_device()],
      );

      await tester.tap(find.byTooltip('Restart live view'));
      await tester.pumpAndSettle();

      expect(fake.starts, [_udid]);
    });
  });

  group('the device control row', () {
    testWidgets('does not sit under the simulator picture', (tester) async {
      // With a phone attached the Android row appeared beneath an iPhone,
      // offering Back, Recents and a screenshot of a device nobody was looking
      // at. Back's arrow is what identifies it: iOS has no such button, so
      // finding one under a simulator's picture can only mean the wrong row.
      await pump(tester, live: _running(), devices: [_device()]);

      expect(find.byIcon(AppIcons.arrowLeft), findsNothing);
      expect(
        find.byKey(const Key('simulator-home')),
        findsOneWidget,
        reason: 'the simulator pane carries its own controls',
      );
    });

    testWidgets('offers Android the same controls the simulator row has', (
      tester,
    ) async {
      // Android had Back, Home and Recents and nothing else, on the platform
      // where `adb` makes a screenshot, an appearance switch and a deep link
      // one command each — while the iOS row beside it offered all three.
      await pump(
        tester,
        live: const SimulatorLiveViewIdle(),
        devices: [_device()],
      );

      expect(find.byKey(const Key('android-back')), findsOneWidget);
      expect(find.byKey(const Key('android-home')), findsOneWidget);
      expect(find.byKey(const Key('android-recents')), findsOneWidget);
      expect(find.byKey(const Key('android-appearance')), findsOneWidget);
      expect(find.byKey(const Key('android-screenshot')), findsOneWidget);
      expect(find.byKey(const Key('android-open-url')), findsOneWidget);
    });

    testWidgets('leaves them all inert while no live view is running', (
      tester,
    ) async {
      // The gate the old hardware-key row was careful about, kept: a control
      // that reaches a device the user believes is disconnected is worse than
      // one that is visibly disabled and says why.
      await pump(
        tester,
        live: const SimulatorLiveViewIdle(),
        devices: [_device()],
      );

      for (final key in const [
        'android-back',
        'android-appearance',
        'android-screenshot',
        'android-open-url',
      ]) {
        expect(
          tester.widget<IconButton>(find.byKey(Key(key))).onPressed,
          isNull,
          reason: '$key must not reach a device with no live view',
        );
      }
      expect(
        find.byTooltip('Start the live view to use the device controls'),
        findsWidgets,
      );
    });
  });
}
