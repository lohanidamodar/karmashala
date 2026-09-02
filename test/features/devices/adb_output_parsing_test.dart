import 'package:karmashala/src/features/devices/data/adb_output_parsing.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/logcat_entry.dart';
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

  group('parseScrcpyForwards', () {
    const output =
        'F6IZLV6LMFT4U4ZT tcp:56213 localabstract:scrcpy_57037a47\n'
        'emulator-5554 tcp:57521 localabstract:scrcpy_12a9795f\n'
        'emulator-5554 tcp:5037 tcp:9000\n';

    test('finds this device scrcpy forwards and nothing else', () {
      // The list is global — `adb forward --list` ignores `-s` — so filtering
      // by serial here is what stops one device tearing down another tunnel.
      expect(parseScrcpyForwards(output, serial: 'emulator-5554'), [57521]);
      expect(parseScrcpyForwards(output, serial: 'F6IZLV6LMFT4U4ZT'), [56213]);
    });

    test('ignores forwards that are not scrcpy', () {
      expect(
        parseScrcpyForwards(
          'emulator-5554 tcp:5037 tcp:9000\n',
          serial: 'emulator-5554',
        ),
        isEmpty,
      );
    });

    test('an empty or unknown listing is empty, not an error', () {
      expect(parseScrcpyForwards('', serial: 'x'), isEmpty);
      expect(parseScrcpyForwards('nonsense', serial: 'x'), isEmpty);
      expect(parseScrcpyForwards(output, serial: 'other'), isEmpty);
    });
  });

  group('parseOwnedScrcpyPids', () {
    // Real `ps -A -o PID,ARGS` output. The jar path only ever appears on the
    // wrapping `sh -c` line — `CLASSPATH` is an environment assignment, not an
    // argument — so the app_process child has to be found by its scid.
    const ps =
        '   PID ARGS\n'
        '     1 init second_stage\n'
        '  8357 sh -c CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process '
        '/ com.genymobile.scrcpy.Server 4.1 scid=0a1b2c3d log_level=info\n'
        '  8359 app_process / com.genymobile.scrcpy.Server 4.1 '
        'scid=0a1b2c3d log_level=info\n'
        ' 11026 sh -c CLASSPATH=/data/local/tmp/karmashala-scrcpy-server.jar '
        'app_process / com.genymobile.scrcpy.Server 4.1 scid=3f3c4fef\n'
        ' 11028 app_process / com.genymobile.scrcpy.Server 4.1 scid=3f3c4fef\n';
    const ours = '/data/local/tmp/karmashala-scrcpy-server.jar';

    test('finds both the shell and the app_process it started', () {
      expect(parseOwnedScrcpyPids(ps, jarPath: ours), [11026, 11028]);
    });

    test('leaves a scrcpy the developer is running alone', () {
      // Matching on the class name would have killed 8357/8359 too, and with
      // them whatever the developer was looking at.
      final pids = parseOwnedScrcpyPids(ps, jarPath: ours);
      expect(pids, isNot(contains(8357)));
      expect(pids, isNot(contains(8359)));
    });

    test('an empty process table yields nothing', () {
      expect(parseOwnedScrcpyPids('', jarPath: ours), isEmpty);
      expect(parseOwnedScrcpyPids('   PID ARGS\n', jarPath: ours), isEmpty);
    });

    test('never returns init', () {
      expect(parseOwnedScrcpyPids('1 $ours scid=1\n', jarPath: ours), isEmpty);
    });
  });

  group('parseNightMode', () {
    test('reads the one line `cmd uimode night` prints', () {
      // Verified against an API 34 emulator, which answers exactly this.
      expect(parseNightMode('Night mode: yes\n'), isTrue);
      expect(parseNightMode('Night mode: no\n'), isFalse);
    });

    test('anything a two-state button cannot represent is unknown', () {
      // `auto` is "whatever the light sensor says" and the custom modes are
      // schedules — none of them a state this app set or can promise. Saying
      // "unknown" lets the caller leave the control alone instead of claiming
      // the device is light while it is dark.
      expect(parseNightMode('Night mode: auto'), isNull);
      expect(parseNightMode('Night mode: custom_schedule'), isNull);
      expect(parseNightMode(''), isNull);
      expect(parseNightMode('cmd: Failure calling service uimode'), isNull);
    });
  });
}
