import 'package:chitragupta/src/features/devices/data/adb_output_parsing.dart';
import 'package:chitragupta/src/features/devices/domain/android_device.dart';
import 'package:chitragupta/src/features/devices/domain/logcat_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAdbDevices', () {
    test('parses a physical device and an emulator with their properties', () {
      const output = '''
List of devices attached
F6IZLV6LMFT4U4ZT       device product:CPH1989 model:CPH1989 device:OP4C4BL1 transport_id:6
emulator-5554          device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64xa transport_id:7
''';
      final devices = parseAdbDevices(output, environmentId: 'windows');

      expect(devices, hasLength(2));
      expect(devices[0].serial, 'F6IZLV6LMFT4U4ZT');
      expect(devices[0].model, 'CPH1989');
      expect(devices[0].product, 'CPH1989');
      expect(devices[0].transportId, '6');
      expect(devices[0].isEmulator, isFalse);
      expect(devices[0].isReady, isTrue);
      expect(devices[0].environmentId, 'windows');

      expect(devices[1].serial, 'emulator-5554');
      expect(devices[1].isEmulator, isTrue);
    });

    test('ignores the header, blank lines and daemon chatter', () {
      const output = '''
* daemon not running; starting now at tcp:5037
* daemon started successfully
List of devices attached

''';
      expect(parseAdbDevices(output, environmentId: 'windows'), isEmpty);
    });

    test(
      'records unauthorized and offline devices rather than dropping them',
      () {
        const output = '''
List of devices attached
ABC123    unauthorized
DEF456    offline
''';
        final devices = parseAdbDevices(output, environmentId: 'windows');
        expect(devices, hasLength(2));
        expect(devices[0].state, DeviceConnectionState.unauthorized);
        expect(devices[0].isReady, isFalse);
        expect(devices[1].state, DeviceConnectionState.offline);
      },
    );

    test('handles a short-form listing with no -l properties', () {
      const output = 'List of devices attached\nABC123\tdevice\n';
      final devices = parseAdbDevices(output, environmentId: 'wsl:Ubuntu');
      expect(devices.single.serial, 'ABC123');
      expect(devices.single.model, isNull);
      expect(devices.single.environmentId, 'wsl:Ubuntu');
    });
  });

  group('parseAvdNames', () {
    test('parses names and skips emulator warning preamble', () {
      const output = '''
INFO    | Storing crashdata in: /tmp/foo
P7A35
Pixel_8_Pro
sambandha_test
''';
      expect(parseAvdNames(output), ['P7A35', 'Pixel_8_Pro', 'sambandha_test']);
    });

    test('returns empty for no AVDs', () {
      expect(parseAvdNames(''), isEmpty);
    });
  });

  group('parseScreenSize', () {
    test('reads the physical size', () {
      expect(parseScreenSize('Physical size: 1080x2340')?.width, 1080);
      expect(parseScreenSize('Physical size: 1080x2340')?.height, 2340);
    });

    test('prefers an override size when the device reports one', () {
      const output = 'Physical size: 1080x2340\nOverride size: 540x1170';
      final size = parseScreenSize(output);
      expect(size?.width, 540);
      expect(size?.height, 1170);
    });

    test('returns null when unparseable', () {
      expect(parseScreenSize('nonsense'), isNull);
    });
  });

  group('parseLogcatLine', () {
    test('parses a threadtime line', () {
      final entry = parseLogcatLine(
        '08-29 20:15:33.123  1234  5678 I MyTag   : hello world',
      );
      expect(entry, isNotNull);
      expect(entry!.pid, 1234);
      expect(entry.tid, 5678);
      expect(entry.level, LogLevel.info);
      expect(entry.tag, 'MyTag');
      expect(entry.message, 'hello world');
      expect(entry.timestamp, '08-29 20:15:33.123');
    });

    test('keeps colons inside the message', () {
      final entry = parseLogcatLine(
        '08-29 20:15:33.123  1  2 E flutter : Error: at 10:30',
      );
      expect(entry!.message, 'Error: at 10:30');
      expect(entry.tag, 'flutter');
    });

    test('returns null for banners and blank lines', () {
      expect(parseLogcatLine('--------- beginning of main'), isNull);
      expect(parseLogcatLine(''), isNull);
    });
  });

  group('parsePidsFromPidof', () {
    test('splits whitespace-separated pids', () {
      expect(parsePidsFromPidof(' 1234 5678 \n'), [1234, 5678]);
    });

    test('returns empty when the package is not running', () {
      expect(parsePidsFromPidof(''), isEmpty);
    });
  });
}
