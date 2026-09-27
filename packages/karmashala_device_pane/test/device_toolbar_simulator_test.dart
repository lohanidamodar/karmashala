import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/pane.dart';
import 'package:agent_cli/process.dart';

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

/// A live view whose stop never finishes, so the pane cannot tell from the
/// state alone that it has already asked.
class _SlowStopLiveView extends _FakeLiveView {
  _SlowStopLiveView(super.initial);

  @override
  Future<void> stop() async {
    stops++;
    await Completer<void>().future;
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
    // Overridable so a case can take the simulator away underneath a running
    // live view, which is what shutting one down does.
    List<IosSimulator>? simulators,
    String? picked = _udid,
    // A live view that is *starting* draws a spinner that never stops, so
    // `pumpAndSettle` would sit there until it timed out.
    bool settle = true,
    _FakeLiveView? liveView,
  }) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = liveView ?? _FakeLiveView(live);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          androidSdkProvider.overrideWith((ref) async => _sdk()),
          devicesProvider.overrideWith((ref) async => devices),
          avdsProvider.overrideWith((ref) async => const <Avd>[]),
          deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
          hostCanRunSimulatorsProvider.overrideWithValue(true),
          iosSimulatorsProvider.overrideWith(
            (ref) async => simulators ?? [_booted()],
          ),
          simulatorBackendProvider.overrideWithValue(_StubBackend()),
          selectedSimulatorUdidProvider.overrideWith(
            () => _PickedSimulator(picked),
          ),
          simulatorLiveViewProvider.overrideWith(() => fake),
          // The iOS "Slim on start" row reads saved settings, which live in
          // the database, and is on screen whenever a simulator is booted.
          slimmingOnStartProvider.overrideWithValue(false),
          slimmingKeptCategoriesProvider.overrideWithValue(const {}),
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
      final fake = await pump(tester, live: _running(), devices: [_device()]);

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
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
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
      final fake = await pump(tester, live: _running(), devices: [_device()]);

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
      final fake = await pump(tester, live: _running(), devices: [_device()]);

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
    testWidgets('gives the simulator\'s Home and Record their own glyphs', (
      tester,
    ) async {
      // Both were a plain circle, icon-only, side by side.
      await pump(tester, live: _running(), devices: [_device()]);

      IconData glyphOf(String key) => tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(Icon),
            ),
          )
          .icon!;
      expect(glyphOf('simulator-home'), isNot(glyphOf('simulator-record')));
    });

    testWidgets('each simulator control has a glyph of its own meaning', (
      tester,
    ) async {
      // Lock was the power glyph — the same one as the toolbar's Shut down
      // beside it, for an act that only sleeps the screen.
      await pump(tester, live: _running(), devices: [_device()]);

      IconData glyphOf(String key) => tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(Icon),
            ),
          )
          .icon!;
      expect(glyphOf('simulator-home'), AppIcons.house);
      expect(glyphOf('simulator-lock'), AppIcons.lockSimple);
      expect(glyphOf('simulator-appearance'), AppIcons.moon);
      expect(glyphOf('simulator-screenshot'), AppIcons.camera);
      expect(glyphOf('simulator-record'), AppIcons.record);
      // Toggles start unselected: nothing has been locked or darkened here.
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('simulator-lock')))
            .isSelected,
        isFalse,
      );
      // Power is the toolbar's shut-down alone.
      expect(find.byIcon(AppIcons.power), findsNWidgets(1));
      // The picture is up, so the toolbar's action is the struck-out eye.
      expect(
        find.widgetWithIcon(TextButton, AppIcons.eyeSlash),
        findsOneWidget,
      );
    });

    testWidgets('does not sit under the simulator picture', (tester) async {
      // With a phone attached the Android row appeared beneath an iPhone,
      // offering Back, Recents and a screenshot of a device nobody was looking
      // at. Back's arrow is what identifies it: iOS has no such button, so
      // finding one under a simulator's picture can only mean the wrong row.
      await pump(tester, live: _running(), devices: [_device()]);

      expect(find.byIcon(AppIcons.arrowUDownLeft), findsNothing);
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
      expect(find.byKey(const Key('android-record')), findsOneWidget);
    });

    testWidgets('Record is inert with no live view, and says why', (
      tester,
    ) async {
      // Everything else on this row reaches the device through adb. Record
      // reaches it through the *frames the picture is made of*, so with no live
      // view there is nothing to write — a different reason from the other
      // buttons', and the tooltip is what carries it.
      await pump(
        tester,
        live: const SimulatorLiveViewIdle(),
        devices: [_device()],
      );

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('android-record')))
            .onPressed,
        isNull,
      );
      expect(
        find.byTooltip('Start the live view to record the screen'),
        findsOneWidget,
      );
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

  group('the power button', () {
    testWidgets('names the simulator on screen, not the emulator', (
      tester,
    ) async {
      // The reported fault: with a simulator's picture up and one Android
      // emulator running, power was still bound to the emulator — so pressing
      // it shut down a device the user was not looking at. Stopping the wrong
      // machine is the worst thing a control on this bar can do, which is why
      // the tooltip now names its target.
      await pump(tester, live: _running(), devices: [_device()]);

      expect(find.byTooltip('Shut down iPhone 17'), findsOneWidget);
      expect(
        find.byTooltip('Stop Pixel'),
        findsNothing,
        reason: 'the emulator nobody is looking at is not the target',
      );
    });

    testWidgets('offers the emulator when that is what the pane is about', (
      tester,
    ) async {
      await pump(
        tester,
        live: const SimulatorLiveViewIdle(),
        devices: [_device()],
        picked: null,
      );

      // In the toolbar: each device's row in the list offers its own Stop, by
      // the same name.
      Finder inToolbar(Finder finder) => find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_DeviceToolbar',
        ),
        matching: finder,
      );
      expect(inToolbar(find.byTooltip('Stop Pixel')), findsOneWidget);
      expect(inToolbar(find.byTooltip('Shut down iPhone 17')), findsNothing);
    });
  });

  group('shutting a simulator down', () {
    testWidgets('asks first, and cancelling leaves it running', (tester) async {
      // Stopping an emulator has always confirmed; stopping a simulator was
      // reachable from the row and the toolbar with no warning at all, and it
      // ends a running machine and the picture the user is looking at.
      await pump(tester, live: _running());

      await tester.tap(find.byTooltip('Shut down iPhone 17'));
      await tester.pumpAndSettle();
      expect(find.text('Shut down iPhone 17?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Shut down iPhone 17?'), findsNothing);
    });
  });

  group('a simulator that goes away', () {
    testWidgets('takes its live view with it', (tester) async {
      // Shutting the simulator down left its picture up, showing the last
      // frame that ever arrived — indistinguishable from a live device that
      // has stopped moving, with every control still offering to drive it.
      final fake = await pump(tester, live: _running(), simulators: const []);
      await tester.pumpAndSettle();

      expect(
        fake.stops,
        greaterThan(0),
        reason: 'the picture cannot outlive the device it is of',
      );
    });

    testWidgets('asks once, not once per rebuild', (tester) async {
      // The check once ran inside `build`, scheduling a stop after every
      // frame until the state changed — so each rebuild while the first stop
      // was in flight asked again.
      final slow = _SlowStopLiveView(_running());
      await pump(
        tester,
        live: _running(),
        simulators: const [],
        liveView: slow,
      );
      await tester.pumpAndSettle();
      expect(slow.stops, 1);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(DevicePane)),
      );
      for (var i = 0; i < 3; i++) {
        container.invalidate(androidSdkProvider);
        await tester.pumpAndSettle();
      }

      expect(slow.stops, 1);
    });
  });
}
