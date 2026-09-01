import '../domain/android_device.dart';
import '../domain/device_input.dart';
import '../domain/logcat_entry.dart';

/// Pure parsers for the text that adb and the emulator print.
///
/// These are deliberately free of any process or I/O concern so the awkward
/// real-world shapes (daemon chatter, unauthorized devices, short listings)
/// can be covered by fast unit tests.

/// Parses `adb devices -l` output.
///
/// Lines look like:
/// `emulator-5554  device product:sdk_gphone64_x86_64 model:Pixel transport_id:7`
/// but a plain `adb devices` prints only `<serial>\t<state>`, and the daemon may
/// print startup chatter before the header. Devices that are not usable
/// (`unauthorized`, `offline`) are **kept**, so the UI can explain why a device
/// the user can see is not working.
List<AndroidDevice> parseAdbDevices(
  String output, {
  required String environmentId,
}) {
  final devices = <AndroidDevice>[];
  for (final rawLine in output.split(RegExp(r'[\r\n]+'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('List of devices')) continue;
    if (line.startsWith('*')) continue; // daemon chatter
    if (line.startsWith('adb:') || line.startsWith('error:')) continue;

    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final serial = parts[0];
    final state = DeviceConnectionState.parse(parts[1]);

    String? property(String key) {
      for (final part in parts.skip(2)) {
        if (part.startsWith('$key:')) return part.substring(key.length + 1);
      }
      return null;
    }

    devices.add(
      AndroidDevice(
        serial: serial,
        environmentId: environmentId,
        state: state,
        model: property('model'),
        product: property('product'),
        transportId: property('transport_id'),
      ),
    );
  }
  return devices;
}

/// Parses `emulator -list-avds`. The emulator prints INFO/WARNING preamble to
/// the same stream, so anything that is not a bare name is dropped.
List<String> parseAvdNames(String output) {
  final names = <String>[];
  for (final rawLine in output.split(RegExp(r'[\r\n]+'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.contains('|')) continue; // "INFO    | ..." log lines
    if (line.startsWith('INFO') ||
        line.startsWith('WARNING') ||
        line.startsWith('ERROR')) {
      continue;
    }
    // AVD names are restricted to word characters, dots and dashes.
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(line)) continue;
    names.add(line);
  }
  return names;
}

/// Parses `adb shell wm size`.
///
/// An `Override size` wins when present: that is what the device is actually
/// displaying, and therefore the coordinate space taps must use.
DeviceScreenSize? parseScreenSize(String output) {
  final pattern = RegExp(r'(Physical|Override) size:\s*(\d+)x(\d+)');
  DeviceScreenSize? physical;
  DeviceScreenSize? override;
  for (final match in pattern.allMatches(output)) {
    final size = DeviceScreenSize(
      width: int.parse(match.group(2)!),
      height: int.parse(match.group(3)!),
    );
    if (match.group(1) == 'Override') {
      override = size;
    } else {
      physical = size;
    }
  }
  return override ?? physical;
}

final _logcatPattern = RegExp(
  r'^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+'
  r'(\d+)\s+(\d+)\s+([VDIWEF])\s+(.*?)\s*:\s(.*)$',
);

/// Parses one line of `logcat -v threadtime`.
///
/// Returns `null` for separator banners (`--------- beginning of main`) and any
/// line that does not match, so callers can simply drop them.
LogcatEntry? parseLogcatLine(String line) {
  final match = _logcatPattern.firstMatch(line.trimRight());
  if (match == null) return null;
  final level = LogLevel.fromCode(match.group(4)!);
  if (level == null) return null;
  return LogcatEntry(
    timestamp: match.group(1)!,
    pid: int.parse(match.group(2)!),
    tid: int.parse(match.group(3)!),
    level: level,
    tag: match.group(5)!.trim(),
    message: match.group(6)!,
  );
}

/// Parses `adb shell pidof <package>` — whitespace-separated pids, or empty
/// when the package is not running.
List<int> parsePidsFromPidof(String output) => [
  for (final token in output.trim().split(RegExp(r'\s+')))
    if (token.isNotEmpty) int.tryParse(token) ?? -1,
].where((pid) => pid > 0).toList();

/// First meaningful line of command output.
///
/// Skips blank lines and adb's `OK` acknowledgement, which `emu` subcommands
/// append after their real answer.
String? firstMeaningfulLine(String output) {
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed == 'OK') continue;
    return trimmed;
  }
  return null;
}

/// Local ports of `adb forward` entries that point at a scrcpy socket on
/// [serial].
///
/// A forward that outlives its server is worse than useless: `adb forward`
/// accepts the host-side TCP connection *before* the device-side socket exists
/// and then closes it, so a stale entry makes a reconnect look like it worked
/// while delivering nothing. Every start therefore reaps the entries left by a
/// previous run.
///
/// Lines look like `SERIAL tcp:56213 localabstract:scrcpy_c7a1b2c3`.
List<int> parseScrcpyForwards(String output, {required String serial}) {
  final ports = <int>[];
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    if (fields[0] != serial) continue;
    if (!fields[2].startsWith('localabstract:scrcpy_')) continue;
    final port = int.tryParse(fields[1].replaceFirst('tcp:', ''));
    if (port != null) ports.add(port);
  }
  return ports;
}

/// Pids of scrcpy servers **this app** started, from `ps -A -o PID,ARGS`.
///
/// Identified by [jarPath] rather than by the scrcpy class name, so a scrcpy
/// the developer is running themselves is never killed. That takes two steps:
/// the jar only appears in the `CLASSPATH=` prefix of the wrapping
/// `sh -c`, never in the `app_process` child's own arguments — the child is
/// matched by the `scid=` its parent line carries.
///
/// ```
/// 11026 sh -c CLASSPATH=/data/local/tmp/karmashala-scrcpy-server.jar \
///       app_process / com.genymobile.scrcpy.Server 4.1 scid=3f3c4fef …
/// 11028 app_process / com.genymobile.scrcpy.Server 4.1 scid=3f3c4fef …
/// ```
List<int> parseOwnedScrcpyPids(String output, {required String jarPath}) {
  final lines = output.split(RegExp(r'[\r\n]+'));
  final scids = <String>{};
  final scidPattern = RegExp(r'scid=([0-9a-fA-F]+)');

  for (final line in lines) {
    if (!line.contains(jarPath)) continue;
    final scid = scidPattern.firstMatch(line)?.group(1);
    if (scid != null) scids.add(scid.toLowerCase());
  }

  final pids = <int>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (!trimmed.contains('com.genymobile.scrcpy.Server') &&
        !trimmed.contains(jarPath)) {
      continue;
    }
    final scid = scidPattern.firstMatch(trimmed)?.group(1)?.toLowerCase();
    final ownsJar = trimmed.contains(jarPath);
    if (!ownsJar && (scid == null || !scids.contains(scid))) continue;
    final pid = int.tryParse(trimmed.split(RegExp(r'\s+')).first);
    if (pid != null && pid > 1) pids.add(pid);
  }
  return pids;
}
