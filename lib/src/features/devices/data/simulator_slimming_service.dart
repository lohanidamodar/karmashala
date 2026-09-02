import 'dart:io';

import '../../../core/process/command_runner.dart';
import '../domain/ios_simulator.dart';
import '../domain/simulator_slimming.dart';
import 'simctl_parsing.dart';

/// The four filesystem operations slimming needs, behind an interface so tests
/// never touch `/private/var/tmp`.
///
/// A test that wrote for real would be editing one of the developer's actual
/// simulators, and the failure mode is not a red test — it is a device that
/// boots into a zombie state days later.
abstract interface class SlimmingFileStore {
  /// Contents of [path], or null when it does not exist.
  Future<String?> readAsString(String path);

  Future<void> writeAsString(String path, String contents);

  /// Renames [from] onto [to], replacing it.
  Future<void> rename(String from, String to);

  /// Deletes [path] if it is there. Not an error when it is not.
  Future<void> delete(String path);
}

/// The real thing, on the local disk.
class LocalSlimmingFileStore implements SlimmingFileStore {
  const LocalSlimmingFileStore();

  @override
  Future<String?> readAsString(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsString();
  }

  @override
  Future<void> writeAsString(String path, String contents) =>
      File(path).writeAsString(contents, flush: true);

  @override
  Future<void> rename(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}

/// Reads a flat `<key>/<true|false>` plist into a map, or returns null when the
/// document is not that shape.
///
/// Null means **refuse to touch it**, not "empty". The file is shared with
/// launchd, which writes entries of its own into it, and a document this parser
/// cannot round-trip is one whose foreign entries a rewrite would silently
/// destroy. A binary plist (`bplist00`) lands here too, since it has no
/// `<dict>` — it has never been observed for this file, but guessing would be
/// the expensive kind of wrong.
Map<String, bool>? parseDisabledPlist(String xml) {
  // `<dict/>` is how an empty dictionary is written; it has no body to scan.
  if (RegExp(r'<dict\s*/>').hasMatch(xml)) return <String, bool>{};

  final open = xml.indexOf('<dict>');
  final close = xml.lastIndexOf('</dict>');
  if (open < 0 || close < open) return null;
  final body = xml.substring(open + '<dict>'.length, close);

  final keyPattern = RegExp(r'<key>([^<]*)</key>');
  final valuePattern = RegExp(r'<(true|false)\s*/>');
  final entries = <String, bool>{};
  var cursor = 0;
  while (true) {
    cursor = _skipWhitespace(body, cursor);
    if (cursor >= body.length) break;
    final key = keyPattern.matchAsPrefix(body, cursor);
    if (key == null) return null;
    cursor = _skipWhitespace(body, key.end);
    final value = valuePattern.matchAsPrefix(body, cursor);
    // A nested dict, an array, a string value — anything but a bool — means
    // this file is not what this build knows how to edit.
    if (value == null) return null;
    entries[_unescapeXml(key.group(1)!)] = value.group(1) == 'true';
    cursor = value.end;
  }
  return entries;
}

/// Writes [entries] as the XML plist CoreSimulator and launchd both read.
///
/// Keys are sorted so that re-running with the same selection produces a
/// byte-identical file, which makes "did anything actually change?" answerable
/// by looking at the device.
String encodeDisabledPlist(Map<String, bool> entries) {
  final keys = entries.keys.toList()..sort();
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>');
  for (final key in keys) {
    buffer
      ..writeln('\t<key>${_escapeXml(key)}</key>')
      ..writeln(entries[key]! ? '\t<true/>' : '\t<false/>');
  }
  buffer
    ..writeln('</dict>')
    ..writeln('</plist>');
  return buffer.toString();
}

int _skipWhitespace(String text, int from) {
  var i = from;
  while (i < text.length && _isWhitespace(text.codeUnitAt(i))) {
    i++;
  }
  return i;
}

bool _isWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d;

String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _unescapeXml(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// The labels a booted device's launchd currently knows about, from
/// `launchctl list`'s three-column table (`PID\tStatus\tLabel`, one header
/// row first).
///
/// Tolerant like the plist parsers above: a row that does not split into
/// three tab-separated fields is skipped rather than thrown over, and the
/// header row itself never matches a label because no real label is called
/// `Label`.
Set<String> parseLaunchctlLabels(String output) {
  final labels = <String>{};
  for (final line in output.split('\n')) {
    final fields = line.split('\t');
    if (fields.length < 3) continue;
    final label = fields[2].trim();
    if (label.isEmpty || label == 'Label') continue;
    labels.add(label);
  }
  return labels;
}

/// What a device's `disabled.plist` currently says.
///
/// Readable on a **shut-down** device, which is the point: `simctl spawn
/// launchctl print` needs a booted one, so it cannot answer "is this simulator
/// slimmed?" for the ninety-odd devices a machine accumulates.
class SlimmingStatus {
  const SlimmingStatus({
    required this.udid,
    required this.plistPath,
    required this.exists,
    required this.entries,
  });

  final String udid;

  /// Where the file is (or would be).
  final String plistPath;

  /// Whether the file is there at all. Absent is the stock state, and means
  /// every service is enabled.
  final bool exists;

  /// The whole file, foreign keys included, or null when it exists but could
  /// not be parsed — see [parseDisabledPlist]. A null here makes [slim] and
  /// [SimulatorSlimmingService.unslim] refuse rather than clobber it.
  final Map<String, bool>? entries;

  bool get readable => entries != null;

  /// Every label the file marks disabled.
  Set<String> get disabled => {
    for (final entry in (entries ?? const <String, bool>{}).entries)
      if (entry.value) entry.key,
  };

  /// Disabled labels this build owns, and would put back.
  Set<String> get disabledManaged => disabled.intersection(allManagedLabels);

  /// Disabled labels somebody else turned off — simslim itself, a hand edit, a
  /// future version of this table. [SimulatorSlimmingService.unslim] leaves
  /// these alone, and a UI should say so rather than claim the device is
  /// un-slimmed.
  Set<String> get disabledUnmanaged => disabled.difference(allManagedLabels);

  bool get isSlimmed => disabledManaged.isNotEmpty;

  /// Categories with every label disabled.
  Set<SlimmingCategory> get fullyDisabledCategories => {
    for (final category in SlimmingCategory.values)
      if (category.labels.isNotEmpty && category.labels.every(disabled.contains))
        category,
  };

  /// Categories with some but not all of their labels disabled — what a
  /// hand-edited or half-upgraded device looks like.
  Set<SlimmingCategory> get partlyDisabledCategories => {
    for (final category in SlimmingCategory.values)
      if (category.labels.any(disabled.contains) &&
          !category.labels.every(disabled.contains))
        category,
  };

  /// What is currently broken on this device as a result, keyed by the label
  /// that broke it.
  Map<String, String> get featureLoss => {
    for (final category in SlimmingCategory.values)
      for (final entry in category.featureLoss.entries)
        if (disabled.contains(entry.key)) entry.key: entry.value,
  };

  @override
  String toString() =>
      'SlimmingStatus($udid exists=$exists readable=$readable '
      'disabled=${disabledManaged.length}+${disabledUnmanaged.length})';
}

/// Switches iOS Simulator background services off by writing the one file that
/// controls them.
///
/// The whole mechanism is
/// `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/disabled.plist` —
/// **not** anything under `~/Library/Developer/CoreSimulator/Devices/<udid>/`,
/// which is where it looks like it should be and is not.
///
/// Writing it directly is both simpler and far faster than driving `launchctl`:
/// simslim boots the device, issues ~170 sequential `launchctl disable` calls
/// (~84 seconds), then reboots to apply them. The file write is sub-millisecond
/// and applies on the *first* boot, so the cost is one boot instead of two plus
/// a minute and a half.
///
/// Every process this runs goes through [runner] (architecture constraint 6),
/// and every file it touches goes through [files].
class SimulatorSlimmingService {
  SimulatorSlimmingService({
    required this.runner,
    this.files = const LocalSlimmingFileStore(),
    this.shutdownTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 500),
  });

  final CommandRunner runner;
  final SlimmingFileStore files;

  /// How long to wait for a device to actually reach Shutdown. `simctl
  /// shutdown` returns as soon as the request is accepted, not when the device
  /// is down.
  final Duration shutdownTimeout;

  /// Gap between state polls. Tests set it to zero.
  final Duration pollInterval;

  static const _xcrun = 'xcrun';

  /// The per-device CoreSimulator scratch directory.
  ///
  /// The UDID is upper-cased because that is how CoreSimulator names the
  /// directory, and `simctl` accepts a lower-case UDID on the command line — so
  /// a caller that got its udid from somewhere lax would otherwise read and
  /// write a path that quietly does not exist, and [status] would report every
  /// device as un-slimmed.
  static String directoryFor(String udid) =>
      '/private/var/tmp/com.apple.CoreSimulator.SimDevice.'
      '${udid.toUpperCase()}';

  static String plistPathFor(String udid) =>
      '${directoryFor(udid)}/disabled.plist';

  /// Reads a device's current slimming state. No `simctl` call, so this works
  /// on a shut-down device and costs one file read.
  Future<SlimmingStatus> status(String udid) async {
    final path = plistPathFor(udid);
    final raw = await files.readAsString(path);
    return SlimmingStatus(
      udid: udid,
      plistPath: path,
      exists: raw != null,
      entries: raw == null ? const <String, bool>{} : parseDisabledPlist(raw),
    );
  }

  /// Disables every managed service except those in [except] / [keep], then
  /// boots the device.
  ///
  /// The device is shut down first if it is running — see [_writeEntries] for
  /// why that is not optional.
  Future<void> slim(
    String udid, {
    Set<SlimmingCategory> except = const {},
    Set<String> keep = const {},
    bool boot = true,
  }) => _writeEntries(
    udid,
    desiredDisabled(except: except, keep: keep),
    boot: boot,
  );

  /// Puts every managed service back, then boots the device.
  ///
  /// This is also the recovery path for a device slimmed too far: shut down,
  /// drop our keys, boot. `simctl erase` is **not** needed, and would throw
  /// away the device's apps and data for nothing.
  ///
  /// Labels this build does not manage are left disabled — see
  /// [SlimmingStatus.disabledUnmanaged].
  Future<void> unslim(String udid, {bool boot = true}) =>
      _writeEntries(udid, const {}, boot: boot);

  /// Labels this build manages that a **booted** device's launchd has never
  /// heard of.
  ///
  /// A label Apple renamed or removed between iOS releases is not an error to
  /// `launchctl` — disabling it, or leaving a now-meaningless entry in
  /// `disabled.plist`, is silently ignored, so a whole category can look like
  /// it is working while doing nothing. This is the drift check: it runs
  /// `launchctl list` against the real device and reports whatever this
  /// build's table names that the device does not.
  ///
  /// Needs a booted device — `simctl spawn` only reaches a running one, which
  /// is why this is a separate call rather than folded into [slim]: slimming
  /// itself only ever touches a shut-down device (see [_ensureShutdown]), and
  /// this check would force a boot first for no other reason.
  Future<Set<String>> staleLabels(String udid) async {
    final result = await runner.run(
      CommandRequest(
        executable: _xcrun,
        arguments: ['simctl', 'spawn', udid, 'launchctl', 'list'],
      ),
    );
    if (!result.ok) {
      throw StateError(
        'Could not list launchd services on $udid: ${result.stderr.trim()}. '
        'The device must be booted for this check — simctl spawn only '
        'reaches a running device.',
      );
    }
    return allManagedLabels.difference(parseLaunchctlLabels(result.stdout));
  }

  Future<void> _writeEntries(
    String udid,
    Set<String> desired, {
    required bool boot,
  }) async {
    await _ensureShutdown(udid);

    final current = await status(udid);
    if (!current.readable) {
      // Rewriting a file we could not parse would drop launchd's own entries,
      // and there is no way to tell the user which ones.
      throw StateError(
        '${current.plistPath} is not a flat boolean plist, so this build will '
        'not rewrite it. Inspect it by hand, or delete it to start from the '
        'stock configuration.',
      );
    }

    final next = applyDelta(current.entries!, desired);
    await _writeAtomically(udid, encodeDisabledPlist(next));

    if (boot) await _boot(udid);
  }

  /// Brings [udid] to Shutdown, or throws.
  ///
  /// **Never write the plist while the device is booted.** launchd reads the
  /// set once at boot and holds it in memory; an edit underneath it is racy —
  /// it may be re-serialised away, or half-applied on the next boot. The write
  /// on a shut-down device is the whole reason this is a single boot rather
  /// than two.
  ///
  /// Note also that [SimulatorState] is not a health check. A device whose
  /// SpringBoard has been disabled still reports Booted forever; state is only
  /// trustworthy for the transition being waited on here.
  Future<void> _ensureShutdown(String udid) async {
    var state = await _stateOf(udid);
    if (state == null) {
      throw StateError('No simulator with UDID $udid.');
    }
    if (state == SimulatorState.shutdown) return;

    final result = await runner.run(
      CommandRequest(executable: _xcrun, arguments: ['simctl', 'shutdown', udid]),
    );
    final deadline = DateTime.now().add(shutdownTimeout);
    while (DateTime.now().isBefore(deadline)) {
      state = await _stateOf(udid);
      if (state == SimulatorState.shutdown) return;
      if (pollInterval > Duration.zero) {
        await Future<void>.delayed(pollInterval);
      }
    }
    final reason = result.ok
        ? 'it was still ${state?.name ?? 'unknown'} after '
              '${shutdownTimeout.inSeconds}s'
        : 'simctl shutdown failed: ${result.stderr.trim()}';
    throw StateError('Could not shut $udid down before editing it — $reason.');
  }

  Future<SimulatorState?> _stateOf(String udid) async {
    final result = await runner.run(
      const CommandRequest(
        executable: _xcrun,
        arguments: ['simctl', 'list', 'devices', '-j'],
      ),
    );
    if (!result.ok) {
      throw StateError('simctl list failed: ${result.stderr.trim()}');
    }
    final wanted = udid.toUpperCase();
    for (final device in parseSimctlDevices(result.stdout)) {
      if (device.udid.toUpperCase() == wanted) return device.state;
    }
    return null;
  }

  /// Writes the plist so that a reader never sees a half-written file.
  ///
  /// The directory is created through the runner rather than `dart:io` because
  /// it must end up mode 0700 and Dart has no chmod; doing both as processes
  /// keeps the two halves of one operation in one place. A fresh device that
  /// has never been booted has no directory at all, so this is the common case,
  /// not the edge case.
  Future<void> _writeAtomically(String udid, String contents) async {
    final directory = directoryFor(udid);
    await runner.run(
      CommandRequest(executable: '/bin/mkdir', arguments: ['-p', directory]),
    );
    await runner.run(
      CommandRequest(executable: '/bin/chmod', arguments: ['0700', directory]),
    );

    final path = plistPathFor(udid);
    final temporary = '$path.tmp';
    try {
      await files.writeAsString(temporary, contents);
      await files.rename(temporary, path);
    } on Object {
      // A leftover `.tmp` is inert to launchd, but it is also a lie about what
      // this build last did, so it does not get to stay.
      await files.delete(temporary);
      rethrow;
    }
  }

  Future<void> _boot(String udid) async {
    final result = await runner.run(
      CommandRequest(executable: _xcrun, arguments: ['simctl', 'boot', udid]),
    );
    if (!result.ok) {
      throw StateError('Could not boot $udid: ${result.stderr.trim()}');
    }
  }
}
