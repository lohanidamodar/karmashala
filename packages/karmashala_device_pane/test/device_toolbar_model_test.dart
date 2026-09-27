import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/src/presentation/device_toolbar_model.dart';

/// What the device toolbar is about, as a plain function of the providers'
/// answers — no widget and no `ProviderScope`.
const _udid = 'UDID-1';

const _emulator = AndroidDevice(
  serial: 'emulator-5554',
  environmentId: 'mac',
  state: DeviceConnectionState.device,
  model: 'Pixel',
);

const _phone = AndroidDevice(
  serial: 'F6IZLV6LMFT4U4ZT',
  environmentId: 'mac',
  state: DeviceConnectionState.device,
  model: 'Pixel 8',
);

const _iphone = IosSimulator(
  udid: _udid,
  name: 'iPhone 17',
  state: SimulatorState.booted,
  runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
  deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
  isAvailable: true,
);

SimulatorLiveViewRunning _running() => SimulatorLiveViewRunning(
  SimulatorLiveView(
    udid: _udid,
    frames: SimulatorFrames(const Stream<Uint8List>.empty()),
    feed: SimulatorVideoFeed(
      url: Uri.parse('http://127.0.0.1:9100/'),
      stop: () async {},
    ),
  ),
);

DeviceToolbarModel _model({
  List<IosSimulator> booted = const [_iphone],
  SimulatorLiveViewState simulatorState = const SimulatorLiveViewIdle(),
  String? chosenSimulator,
  String? chosenAndroid,
  AndroidDevice? selected,
  bool canStopEmulator = true,
  bool stoppingEmulator = false,
  Set<String> busySimulators = const {},
  bool starting = false,
  bool streaming = false,
}) => DeviceToolbarModel.from(
  bootedSimulators: booted,
  simulatorState: simulatorState,
  chosenSimulator: chosenSimulator,
  chosenAndroid: chosenAndroid,
  selected: selected,
  canStopEmulator: canStopEmulator,
  stoppingEmulator: stoppingEmulator,
  busySimulators: busySimulators,
  starting: starting,
  streaming: streaming,
);

void main() {
  group('the primary stream action', () {
    test('a start in flight is a spinner, whatever else is true', () {
      expect(
        _model(
          starting: true,
          streaming: true,
          simulatorState: _running(),
        ).primary,
        PrimaryStreamKind.starting,
      );
    });

    test('a simulator picture up means Stop the simulator, even with a '
        'phone streaming', () {
      expect(
        _model(simulatorState: _running(), streaming: true).primary,
        PrimaryStreamKind.stopSimulator,
      );
      // A failed start still names a simulator, and Stop dismisses it.
      expect(
        _model(
          simulatorState: const SimulatorLiveViewFailed(_udid, 'no'),
        ).primary,
        PrimaryStreamKind.stopSimulator,
      );
    });

    test('a picked simulator offers its live view', () {
      final model = _model(chosenSimulator: _udid, selected: _phone);
      expect(model.pickedSimulator, _udid);
      expect(model.primary, PrimaryStreamKind.startSimulator);
    });

    test('an explicit Android choice outranks a remembered simulator pick', () {
      final model = _model(
        chosenSimulator: _udid,
        chosenAndroid: _phone.serial,
        selected: _phone,
      );
      expect(model.pickedSimulator, isNull);
      expect(model.primary, PrimaryStreamKind.startAndroid);
    });

    test('a pick of a simulator that is no longer booted is not a pick', () {
      expect(
        _model(booted: const [], chosenSimulator: _udid).pickedSimulator,
        isNull,
      );
    });

    test('Android streaming is Stop, otherwise Live view', () {
      expect(_model(streaming: true).primary, PrimaryStreamKind.stopAndroid);
      expect(_model().primary, PrimaryStreamKind.startAndroid);
    });
  });

  group('restart', () {
    test('is offered for a running or failed simulator, never a starting '
        'one', () {
      expect(_model(simulatorState: _running()).restartableSimulator, _udid);
      expect(
        _model(
          simulatorState: const SimulatorLiveViewFailed(_udid, 'no'),
        ).restartableSimulator,
        _udid,
      );
      final starting = _model(
        simulatorState: const SimulatorLiveViewStarting(_udid),
      );
      expect(starting.restartableSimulator, isNull);
      expect(starting.liveSimulator, _udid);
    });
  });

  group('the power target', () {
    test('a simulator on screen wins over a selected emulator', () {
      final target = _model(
        simulatorState: _running(),
        selected: _emulator,
      ).powerTarget;
      expect(target, isA<SimulatorPowerTarget>());
      expect(target!.name, 'iPhone 17');
    });

    test('an unknown simulator is still named', () {
      final target = _model(
        booted: const [],
        simulatorState: _running(),
      ).powerTarget;
      expect(target!.name, 'this simulator');
    });

    test('an emulator, but never a phone', () {
      expect(
        _model(selected: _emulator).powerTarget,
        isA<AndroidPowerTarget>(),
      );
      expect(_model(selected: _phone).powerTarget, isNull);
      expect(
        _model(selected: _emulator, canStopEmulator: false).powerTarget,
        isNull,
      );
    });

    test('is busy while its device is on the way down', () {
      expect(
        _model(selected: _emulator, stoppingEmulator: true).powerBusy,
        isTrue,
      );
      expect(
        _model(
          simulatorState: _running(),
          busySimulators: const {_udid},
        ).powerBusy,
        isTrue,
      );
      expect(_model(selected: _emulator).powerBusy, isFalse);
    });
  });
}
