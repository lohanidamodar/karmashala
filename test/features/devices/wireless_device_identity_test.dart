import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala/src/features/devices/data/adb_output_parsing.dart';
import 'package:karmashala/src/features/devices/data/adb_service.dart';
import 'package:karmashala/src/features/devices/data/device_stream.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/device_target.dart';

import '../../support/fake_command_runner.dart';

/// What `adb devices -l` prints with the owner's phone on a cable and a second
/// one attached over Wi-Fi. A wireless device identifies itself by address, not
/// by hardware serial, so both shapes are in one listing.
const _bothShapes = '''
List of devices attached
F6IZLV6LMFT4U4ZT       device product:CPH1989 model:CPH1989 device:OP4B75 transport_id:1
192.168.1.24:37129     device product:redfin model:Pixel_5 device:redfin transport_id:2
''';

const _cabled = 'F6IZLV6LMFT4U4ZT';
const _wireless = '192.168.1.24:37129';

const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

ProviderContainer _container(FakeCommandRunner runner) {
  final container = ProviderContainer(
    overrides: [
      adbServiceProvider.overrideWithValue(
        AdbService(runner: runner, sdk: _sdk),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

FakeCommandRunner _listing(String stdout) => FakeCommandRunner(
  responder: (_) => CommandResult(exitCode: 0, stdout: stdout, stderr: ''),
);

void main() {
  group('two devices, two shapes of id', () {
    test('both are listed, and neither is read as an emulator', () {
      final devices = parseAdbDevices(_bothShapes, environmentId: 'windows');
      expect(devices.map((d) => d.serial), [_cabled, _wireless]);
      expect(devices.every((d) => d.isReady), isTrue);
      expect(
        devices.every((d) => !d.isEmulator),
        isTrue,
        reason: 'neither offers `emu kill`, which only an emulator answers',
      );
      expect(devices.last.displayName, 'Pixel_5');
    });

    test('the address-shaped id survives the whitespace split intact', () {
      final devices = parseAdbDevices(_bothShapes, environmentId: 'windows');
      expect(devices.last.serial, _wireless);
      expect(devices.last.transportId, '2');
    });

    test('a wireless device is a normal row, so the pane is not unavailable', () {
      final devices = parseAdbDevices(
        'List of devices attached\n$_wireless\tdevice\n',
        environmentId: 'windows',
      );
      expect(
        deviceUnavailableReason(
          sdk: _sdk,
          sdkResolved: true,
          devices: devices,
          kind: EnvironmentKind.windowsNative,
        ),
        isNull,
      );
    });

    test('the stream picks the hardware encoder for it, as for any handset', () {
      expect(DeviceStreamService.isEmulatorSerial(_wireless), isFalse);
      expect(DeviceStreamService.isEmulatorSerial(_cabled), isFalse);
    });
  });

  group('the selection', () {
    test('an explicit cabled choice survives a wireless device appearing', () async {
      final runner = _listing(_bothShapes);
      final container = _container(runner);
      container.read(selectedDeviceSerialProvider.notifier).select(_cabled);
      await container.read(devicesProvider.future);

      expect(container.read(selectedDeviceProvider)?.serial, _cabled);
    });

    test('an explicit wireless choice is honoured the same way', () async {
      final runner = _listing(_bothShapes);
      final container = _container(runner);
      container.read(selectedDeviceSerialProvider.notifier).select(_wireless);
      await container.read(devicesProvider.future);

      expect(container.read(selectedDeviceProvider)?.serial, _wireless);
    });

    test('with two ready devices and no choice, nothing is picked for you', () async {
      // Pre-existing rule of [selectedDeviceProvider] — the convenience default
      // answers only when there is exactly one ready device, and a second USB
      // phone does this too. Pinned here because pairing a phone is now a way
      // to reach it.
      final runner = _listing(_bothShapes);
      final container = _container(runner);
      await container.read(devicesProvider.future);

      expect(container.read(selectedDeviceProvider), isNull);
    });
  });

  group('a device id used as a filename', () {
    test('an address-shaped id loses the characters a path objects to', () {
      expect(fileSafeDeviceId(_wireless), '192.168.1.24-37129');
    });

    test('a hardware serial is left exactly as it is', () {
      expect(fileSafeDeviceId(_cabled), _cabled);
      expect(fileSafeDeviceId('emulator-5554'), 'emulator-5554');
    });

    test('a target answers for itself', () {
      const target = AndroidTarget(
        AndroidDevice(
          serial: _wireless,
          environmentId: 'windows',
          state: DeviceConnectionState.device,
        ),
      );
      expect(target.fileSafeId, '192.168.1.24-37129');
    });

    test('the screenshot it pulls does not land on a colon', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        ),
      );
      final adb = AdbService(
        runner: runner,
        sdk: _sdk,
        readHostFile: (_) async => Uint8List.fromList(const [1, 2, 3]),
      );

      await adb.screenshot(_wireless);

      final pull = runner.requests.firstWhere(
        (r) => r.arguments.contains('pull'),
      );
      final destination = pull.arguments.last;
      expect(destination, contains('192.168.1.24-37129'));
      expect(
        destination.substring(destination.indexOf('karmashala')),
        isNot(contains(':')),
        reason: 'a colon on Windows opens an alternate data stream instead',
      );
    });
  });
}
