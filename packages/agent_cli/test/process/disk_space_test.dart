import 'package:agent_cli/src/process/disk_space.dart';
import 'package:test/test.dart';

/// Free space, measured rather than described.
///
/// `C:` reached 97% on this machine on 2026-09-03 and what it produced was a
/// failed link, an emulator that would not boot and a checkpoint that would not
/// write — three hours spent on three wrong problems. The parsers exist so the
/// number in the panel is either right or absent.
void main() {
  group('the command', () {
    test('Windows asks .NET for longs, not a rendered table', () {
      final request = diskSpaceRequest(onWindows: true, path: r'C:\');
      expect(request.executable, 'powershell');
      expect(request.arguments, contains('-NoProfile'));
      // `dir` prints thousands separators in the user's locale; DriveInfo does
      // not print at all.
      expect(request.arguments.last, contains('IO.DriveInfo'));
      expect(request.arguments.last, contains(r'C:\'));
    });

    test('POSIX uses df -P, whose columns cannot move', () {
      final request = diskSpaceRequest(onWindows: false, path: '/');
      expect(request.executable, 'df');
      expect(request.arguments, ['-Pk', '/']);
    });
  });

  group('parsing Windows output', () {
    test('reads the marked lines', () {
      final space = parseDiskSpace(
        '${kDiskMarker}free=42949672960\n${kDiskMarker}total=511000000000\n',
        onWindows: true,
      );
      expect(space, isNotNull);
      expect(space!.freeBytes, 42949672960);
      expect(space.totalBytes, 511000000000);
      expect(space.usedPercent, 92);
    });

    test('a half-answer is no answer', () {
      expect(
        parseDiskSpace('${kDiskMarker}free=1000\n', onWindows: true),
        isNull,
      );
      expect(parseDiskSpace('', onWindows: true), isNull);
    });

    test('a profile banner does not become a number', () {
      final space = parseDiskSpace(
        'Loading personal profile...\n'
        '${kDiskMarker}free=100\n'
        '${kDiskMarker}total=200\n',
        onWindows: true,
      );
      expect(space!.usedPercent, 50);
    });
  });

  group('parsing df output', () {
    test('reads 1024-byte blocks off the first row', () {
      final space = parseDiskSpace(
        'Filesystem     1024-blocks      Used Available Capacity Mounted on\n'
        '/dev/sda1        104857600  94371840  10485760      90% /\n',
        onWindows: false,
      );
      expect(space!.freeBytes, 10485760 * 1024);
      expect(space.totalBytes, 104857600 * 1024);
      expect(space.usedPercent, 90);
    });

    test('a header with no row is no answer', () {
      expect(
        parseDiskSpace(
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n',
          onWindows: false,
        ),
        isNull,
      );
    });

    test('a row of words is no answer rather than a zero', () {
      expect(
        parseDiskSpace('header\ndf: /nope: No such file\n', onWindows: false),
        isNull,
      );
    });
  });

  group('formatting', () {
    test('scales to the unit a person reads', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(42949672960), '40.0 GB');
    });

    test('drops the decimal once it stops meaning anything', () {
      expect(formatBytes(511000000000), '476 GB');
    });
  });

  test('an unknown total never renders as an empty disk', () {
    const space = DiskSpace(freeBytes: 0, totalBytes: 0);
    expect(space.usedFraction, 0);
    expect(space.usedPercent, 0);
  });
}
