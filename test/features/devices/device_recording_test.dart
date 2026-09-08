import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/device_recording.dart';
import 'package:karmashala/src/features/devices/domain/device_target.dart';
import 'package:karmashala/src/features/devices/domain/ios_simulator.dart';

AndroidTarget _android(String serial) => AndroidTarget(
  AndroidDevice(
    serial: serial,
    environmentId: 'windows',
    state: DeviceConnectionState.device,
  ),
);

SimulatorTarget _simulator(String udid) => SimulatorTarget(
  IosSimulator(
    udid: udid,
    name: 'iPhone 17',
    state: SimulatorState.booted,
    runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-0',
    deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
    isAvailable: true,
  ),
);

void main() {
  group('where a recording goes', () {
    final startedAt = DateTime.utc(2026, 9, 8, 14, 3, 7);

    test('a wireless serial cannot reach the filename', () {
      final path = deviceRecordingPath(
        target: _android('192.168.1.24:37129'),
        directory: r'C:\data\recordings',
        startedAt: startedAt,
        extension: 'ts',
      );
      expect(path, isNot(contains(':37129')));
      expect(p.basename(path), '192.168.1.24-37129-20260908-140307.ts');
    });

    test('an mDNS serial cannot reach the filename either', () {
      final path = deviceRecordingPath(
        target: _android('adb-2B071FDH300JJ9-zcg43M._adb-tls-connect._tcp'),
        directory: '/tmp/rec',
        startedAt: startedAt,
        extension: 'ts',
      );
      expect(
        p.basename(path),
        'adb-2B071FDH300JJ9-zcg43M._adb-tls-connect._tcp-20260908-140307.ts',
      );
    });

    test('a hardware serial is left as it is', () {
      final path = deviceRecordingPath(
        target: _android('F6IZLV6LMFT4U4ZT'),
        directory: '/tmp/rec',
        startedAt: startedAt,
        extension: 'ts',
      );
      expect(p.basename(path), 'F6IZLV6LMFT4U4ZT-20260908-140307.ts');
    });

    test('a simulator udid keeps its extension', () {
      final path = deviceRecordingPath(
        target: _simulator('70592006-11CD-4E1F-9A2B-000000000001'),
        directory: '/tmp/rec',
        startedAt: startedAt,
        extension: 'mov',
      );
      expect(path, endsWith('.mov'));
      expect(path, contains('70592006-11CD-4E1F-9A2B-000000000001'));
    });

    test('the stamp carries no colon on any platform', () {
      final path = deviceRecordingPath(
        target: _android('emulator-5554'),
        directory: r'C:\rec',
        startedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        extension: 'ts',
      );
      expect(p.basename(path), 'emulator-5554-20260102-030405.ts');
      expect(path, startsWith(r'C:\rec'));
    });
  });

  group('how long it ran', () {
    test('seconds under a minute', () {
      expect(formatRecordingLength(const Duration(seconds: 9)), '9s');
    });

    test('minutes and seconds above one', () {
      expect(
        formatRecordingLength(const Duration(minutes: 2, seconds: 4)),
        '2m 04s',
      );
    });

    test('hours are spelt out rather than counted as minutes', () {
      expect(
        formatRecordingLength(const Duration(hours: 1, minutes: 5, seconds: 6)),
        '1h 05m 06s',
      );
    });
  });

  group('what the user is told when it ends', () {
    final target = _android('emulator-5554');

    test('a saved recording names the file, the frames and the length', () {
      final outcome = DeviceRecordingOutcome.saved(
        target: target,
        path: '/rec/emulator-5554-20260908-140307.ts',
        bytes: 4404019,
        length: const Duration(seconds: 12),
      );
      expect(outcome.result, DeviceRecordingResult.saved);
      expect(
        outcome.message,
        'Recording saved to /rec/emulator-5554-20260908-140307.ts — '
        '4.2 MB over 12s.',
      );
    });

    test('a gap in the capture is its own sentence, not a footnote', () {
      final outcome = DeviceRecordingOutcome.saved(
        target: target,
        path: '/rec/a.ts',
        bytes: 4404019,
        length: const Duration(seconds: 12),
        gaps: 1,
      );
      expect(
        outcome.message,
        contains(
          'The live view was off for part of it, so the picture jumps once.',
        ),
      );
    });

    test('two gaps are counted rather than pluralised into one', () {
      expect(
        DeviceRecordingOutcome.saved(
          target: target,
          path: '/rec/a.ts',
          bytes: 1128,
          length: const Duration(seconds: 1),
          gaps: 2,
        ).message,
        contains('the picture jumps 2 times'),
      );
    });

    test('a rotation is reported, because the file changes size at it', () {
      expect(
        DeviceRecordingOutcome.saved(
          target: target,
          path: '/rec/a.ts',
          bytes: 1128,
          length: const Duration(seconds: 1),
          geometryChanges: 1,
        ).message,
        contains(
          'The device rotated during it, so the picture changes size '
          'partway through.',
        ),
      );
    });

    test('a recording with no frames says nothing was captured', () {
      final outcome = DeviceRecordingOutcome.empty(
        target: target,
        reason: 'the live view never sent a frame',
      );
      expect(outcome.result, DeviceRecordingResult.empty);
      expect(outcome.path, isNull);
      expect(
        outcome.message,
        'Nothing was recorded from emulator-5554: the live view never sent a '
        'frame. The empty file was removed.',
      );
    });

    test('a file that could not be opened says so and names no length', () {
      final outcome = DeviceRecordingOutcome.failed(
        target: target,
        reason: 'PathAccessException: read-only file system',
        path: '/rec/a.ts',
      );
      expect(outcome.result, DeviceRecordingResult.failed);
      expect(
        outcome.message,
        'Recording failed: /rec/a.ts could not be written — '
        'PathAccessException: read-only file system.',
      );
    });

    test('a write that failed part way keeps what it had, and says so', () {
      final outcome = DeviceRecordingOutcome.writeFailed(
        target: target,
        path: '/rec/a.ts',
        reason: 'FileSystemException: There is not enough space on the disk',
        bytes: 3145728,
      );
      expect(outcome.result, DeviceRecordingResult.failed);
      expect(
        outcome.message,
        'Recording stopped: writing to /rec/a.ts failed — FileSystemException: '
        'There is not enough space on the disk. 3.0 MB was saved before it.',
      );
    });
  });
}
