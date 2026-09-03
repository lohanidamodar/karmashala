import 'command_runner.dart';

/// Free and total bytes on one volume.
///
/// Worth a row on a health panel because it is the failure that arrives
/// disguised as five other failures: on 2026-09-03 `C:` reached 97% here and
/// what the machine reported was a build that would not link, an emulator that
/// would not boot and a checkpoint that would not write. A number, measured,
/// beside them is what stops the next hour going into the wrong one.
class DiskSpace {
  const DiskSpace({required this.freeBytes, required this.totalBytes});

  final int freeBytes;
  final int totalBytes;

  /// Fraction of the volume in use, 0–1. `0` when the total is unknown, which
  /// reads as "nothing measured" rather than "empty".
  double get usedFraction =>
      totalBytes <= 0 ? 0 : (totalBytes - freeBytes) / totalBytes;

  int get usedPercent => (usedFraction * 100).round();
}

/// Marks the lines of [diskSpaceRequest]'s output as ours — see [kEnvMarker].
const String kDiskMarker = '__karmashala_disk:';

/// Command that reports free and total bytes for the volume holding [path].
///
/// **Neither branch parses a human-readable table**, and that is the point.
/// `dir` on Windows and `df -h` on POSIX both render numbers for a person —
/// thousands separators, `1.9G`, a column order that moves — and a locale this
/// developer does not have would silently turn a health check into a wrong
/// number. `[IO.DriveInfo]` returns .NET longs and `df -Pk` is the POSIX
/// standard's fixed-column form, so both come back as digits in a known place.
CommandRequest diskSpaceRequest({
  required bool onWindows,
  required String path,
}) => onWindows
    ? CommandRequest(
        executable: 'powershell',
        arguments: [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$d = [IO.DriveInfo]::new('$path'); "
              "Write-Output ('${kDiskMarker}free=' + \$d.AvailableFreeSpace); "
              "Write-Output ('${kDiskMarker}total=' + \$d.TotalSize)",
        ],
      )
    : CommandRequest(executable: 'df', arguments: ['-Pk', path]);

/// Reads [diskSpaceRequest]'s output, or `null` when it said nothing usable.
///
/// Null rather than a zero: `dataPartitionUse` in `AdbService` settled this one
/// already — a wrong number in a health row is worse than no number.
DiskSpace? parseDiskSpace(String stdout, {required bool onWindows}) =>
    onWindows ? _parseWindows(stdout) : _parseDf(stdout);

DiskSpace? _parseWindows(String stdout) {
  int? free;
  int? total;
  for (final raw in stdout.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (!line.startsWith(kDiskMarker)) continue;
    final body = line.substring(kDiskMarker.length);
    final split = body.indexOf('=');
    if (split <= 0) continue;
    final value = int.tryParse(body.substring(split + 1).trim());
    if (value == null) continue;
    switch (body.substring(0, split)) {
      case 'free':
        free = value;
      case 'total':
        total = value;
    }
  }
  if (free == null || total == null || total <= 0) return null;
  return DiskSpace(freeBytes: free, totalBytes: total);
}

/// `df -Pk` prints a header and then one row per filesystem, in 1024-byte
/// blocks: `Filesystem 1024-blocks Used Available Capacity Mounted-on`.
///
/// POSIX guarantees the row is on **one** line — that is what `-P` is for;
/// without it a long device name wraps and the columns move.
DiskSpace? _parseDf(String stdout) {
  final lines = stdout
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length < 2) return null;
  final fields = lines[1].split(RegExp(r'\s+'));
  if (fields.length < 4) return null;
  final totalKb = int.tryParse(fields[1]);
  final freeKb = int.tryParse(fields[3]);
  if (totalKb == null || freeKb == null || totalKb <= 0) return null;
  return DiskSpace(freeBytes: freeKb * 1024, totalBytes: totalKb * 1024);
}

/// Bytes as a person reads them. Binary units, because that is what both
/// `DriveInfo` and `df -Pk` are counting in.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
