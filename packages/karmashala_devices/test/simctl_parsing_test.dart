import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/simctl_parsing.dart';
import 'package:karmashala_devices/src/domain/ios_simulator.dart';

/// Shapes taken from real `xcrun simctl list devices -j` output on Xcode 26.6.
const _real = '''
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-4" : [
      {
        "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/705/data",
        "dataPathSize" : 18337792,
        "udid" : "70592006-11CD-44A3-96BC-25EE8E72CA3D",
        "isAvailable" : true,
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        "state" : "Booted",
        "name" : "iPhone 17 Pro"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-15-4" : [
      {
        "udid" : "11111111-2222-3333-4444-555555555555",
        "isAvailable" : false,
        "availabilityError" : "runtime profile not found",
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-8",
        "state" : "Shutdown",
        "name" : "iPhone 8"
      }
    ]
  }
}
''';

void main() {
  group('parseSimctlDevices', () {
    test('reads every runtime, and keeps the runtime each device belongs to', () {
      final devices = parseSimctlDevices(_real);

      expect(devices, hasLength(2));
      final booted = devices.first;
      expect(booted.udid, '70592006-11CD-44A3-96BC-25EE8E72CA3D');
      expect(booted.name, 'iPhone 17 Pro');
      expect(booted.state, SimulatorState.booted);
      expect(booted.runtime, 'com.apple.CoreSimulator.SimRuntime.iOS-26-4');
      expect(booted.dataPathSize, 18337792);
      expect(booted.isAvailable, isTrue);
    });

    test('an unavailable simulator is listed, and says so', () {
      // It is still a row in the device set, and hiding it would leave a user
      // wondering where their device went; offering it as bootable would leave
      // them staring at a spinner.
      final stale = parseSimctlDevices(_real).last;

      expect(stale.name, 'iPhone 8');
      expect(stale.isAvailable, isFalse);
      expect(stale.state, SimulatorState.shutdown);
    });

    test('names a device by model and runtime, because the model repeats', () {
      final devices = parseSimctlDevices(_real);

      expect(devices.first.runtimeName, 'iOS 26.4');
      expect(devices.first.displayName, 'iPhone 17 Pro · iOS 26.4');
      expect(devices.last.runtimeName, 'iOS 15.4');
    });

    test('a runtime identifier it does not recognise is shown as it is', () {
      final devices = parseSimctlDevices('''
        {"devices": {"something.else": [
          {"udid": "u", "name": "n", "state": "Shutdown"}
        ]}}
      ''');

      expect(devices.single.runtimeName, 'something.else');
    });

    test('every state simctl writes', () {
      expect(SimulatorState.parse('Booted'), SimulatorState.booted);
      expect(SimulatorState.parse('Booting'), SimulatorState.booting);
      expect(SimulatorState.parse('Shutting Down'), SimulatorState.shuttingDown);
      expect(SimulatorState.parse('Shutdown'), SimulatorState.shutdown);
      // Creating is not running and cannot be talked to; shutdown is the
      // honest reading, not a state of its own the UI must learn.
      expect(SimulatorState.parse('Creating'), SimulatorState.shutdown);
      expect(SimulatorState.parse('Wat'), SimulatorState.unknown);
      expect(SimulatorState.booted.isReady, isTrue);
      expect(SimulatorState.booting.isReady, isFalse);
    });

    test('a bad document costs nothing rather than everything', () {
      // A simulator list is a convenience. One malformed row must not lose the
      // user the other twenty.
      expect(parseSimctlDevices('not json'), isEmpty);
      expect(parseSimctlDevices('[]'), isEmpty);
      expect(parseSimctlDevices('{}'), isEmpty);
      expect(parseSimctlDevices('{"devices": []}'), isEmpty);
      expect(parseSimctlDevices('{"devices": {"rt": "nope"}}'), isEmpty);
      expect(
        parseSimctlDevices('{"devices": {"rt": [{"name": "no udid"}]}}'),
        isEmpty,
      );
      expect(
        parseSimctlDevices('{"devices": {"rt": [{"udid": "u"}]}}'),
        isEmpty,
        reason: 'a device with no name has nothing to show a user',
      );
    });

    test('a device with no isAvailable key is available', () {
      // simctl omits it for a healthy device on some versions.
      final devices = parseSimctlDevices(
        '{"devices": {"rt": [{"udid": "u", "name": "n", "state": "Booted"}]}}',
      );

      expect(devices.single.isAvailable, isTrue);
    });
  });

  group('parseSimctlScreenSize', () {
    /// Real output from a booted iPhone 17 Pro on Xcode 26.6.
    const enumerate = """
Port:
    UUID: 08246516-F8D9-42CB-A4E5-CF060FFC65D7
    Class: Unknown
    Port Identifier: com.apple.display.captureservice
    Power state: On

Port:
    UUID: 847B14E3-B8EC-4BE0-9565-E8B8E956CCFD
    Class: Display
    Port Identifier: com.apple.framebuffer.display
    Power state: On
    Display class: 1
    Default width: 720
    Default height: 480
    Default pixel format: 'BGRA'

Port:
    UUID: D6162B93-A4C8-4613-AB8B-AD6959364223
    Class: Display
    Port Identifier: com.apple.framebuffer.display
    Power state: On
    Display class: 0
    Default width: 1206
    Default height: 2622
    Default pixel format: 'BGRA'
    IOSurface port:
        width              = 1206
        height             = 2622
        bytes per row      = 4864
""";

    test('takes the phone, not the first display in the list', () {
      // The first width/height pair here is a 720x480 display with
      // `Display class: 1`. Taking it — or the first `width:` line anywhere,
      // which also matches the IOSurface sub-block — reports a 720x480 phone,
      // and every coordinate derived from it is wrong. Caught by running this
      // against a real booted simulator, where it returned null.
      expect(parseSimctlScreenSize(enumerate), (width: 1206, height: 2622));
    });

    test('falls back to the largest display when none declares class 0', () {
      const noInternal = """
Port:
    Class: Display
    Display class: 2
    Default width: 100
    Default height: 100

Port:
    Class: Display
    Display class: 1
    Default width: 800
    Default height: 600
""";
      expect(parseSimctlScreenSize(noInternal), (width: 800, height: 600));
    });

    test('null when the shape is not the one this build knows', () {
      expect(parseSimctlScreenSize(''), isNull);
      expect(parseSimctlScreenSize('Port:\n    Class: Display'), isNull);
      expect(
        parseSimctlScreenSize(
          'Port:\n    Class: Display\n    Default width: 0\n'
          '    Default height: 9',
        ),
        isNull,
      );
      expect(
        parseSimctlScreenSize('width = 1206\nheight = 2622'),
        isNull,
        reason: 'the IOSurface sub-block alone is not a display',
      );
    });
  });
}
