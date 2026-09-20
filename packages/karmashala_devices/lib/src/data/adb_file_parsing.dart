import '../domain/device_files.dart';

/// Pure parsers for what an Android shell prints about files. `ls -l` is not one
/// format: toybox, toolbox and busybox each print a different one, the date
/// column alone has two spellings, and an unstattable entry prints `?` columns.

/// Wraps [value] for the **device's** shell. `adb shell <words…>` passes no
/// argv — adb joins with spaces and `sh` splits again — so a path with a space,
/// a `;` or a `$` arrives as something else. Single quotes interpret nothing.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Why an `ls` produced no listing. Classified rather than worded here: the
/// sentence wants the device's name and this file has never heard of one.
enum LsFailure {
  /// The shell user is not allowed. Most of `/data` on any device.
  permissionDenied,

  /// Nothing is at that path.
  missing,

  /// Something is, but it is a file.
  notADirectory,

  /// `ls` failed and said something this build does not recognise. Kept apart so
  /// the message can quote the device verbatim instead of guessing.
  unknown,
}

/// What went wrong with an `ls`, or null when nothing did. Decided from the
/// **output**: `adb shell` forwarded no remote exit code before Android 7, and
/// even a modern listing can succeed overall while printing a per-entry error.
LsFailure? classifyLsFailure(String output, {required bool ok}) {
  final text = output.toLowerCase();
  if (text.contains('permission denied') ||
      text.contains('operation not permitted')) {
    return LsFailure.permissionDenied;
  }
  if (text.contains('no such file or directory')) return LsFailure.missing;
  if (text.contains('not a directory')) return LsFailure.notADirectory;
  // `ls:` prefixes every message toybox emits about a path it could not use.
  if (!ok || RegExp(r'^\s*ls:', multiLine: true).hasMatch(output)) {
    return LsFailure.unknown;
  }
  return null;
}

/// The mode word: `drwxrwx---`, `-rw-rw----`, or `d?????????` from a device
/// that could not stat the entry. A trailing `.` or `+` is SELinux and ACL
/// respectively, and both are ignored.
final _mode = RegExp(r'^([bcdlps-])([rwxsStTl?-]{9})[.+@]?$');

/// The two timestamps `ls` prints, either of which ends the fixed columns and
/// begins the name: `2026-09-03 18:52` from toybox, `Sep  3 18:52` from busybox
/// — the second omits the year, which is why nothing here builds a `DateTime`.
final _timestamp = RegExp(
  r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?)'
  r'|((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+'
  r'(?:\d{4}|\d{1,2}:\d{2}))',
);

/// The shape a device prints for an entry it could not stat, seen on the owner's
/// own handset at `/`:
///
/// ```
/// d?????????   ? ?      ?             ?                ? data_mirror
/// l?????????   ? ?      ?             ?                ? init -> ?
/// ```
///
/// The name is real and the metadata is not.
final _unstattable = RegExp(r'^\S+(?:\s+\?)+\s+(.+)$');

/// Parses `ls -la <dir>/` into a listing of [directory]. A line this cannot read
/// becomes a [SkippedDeviceEntry], never an exception and never an invented row.
/// Columns are read *backwards* from the timestamp: the count is not stable.
DeviceDirectoryListing parseLsLong(String output, {required String directory}) {
  final entries = <DeviceFileEntry>[];
  final skipped = <SkippedDeviceEntry>[];

  for (final rawLine in output.split(RegExp(r'[\r\n]+'))) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) continue;
    // `total 1392`, the block count ls puts above a long listing.
    if (RegExp(r'^total\s+\d+$').hasMatch(line.trim())) continue;
    // A per-entry complaint, which is about a *path* and not a row.
    if (line.trimLeft().startsWith('ls:')) {
      skipped.add(
        SkippedDeviceEntry(line: line.trim(), reason: 'the device refused it'),
      );
      continue;
    }

    final firstSpace = line.indexOf(RegExp(r'\s'));
    if (firstSpace <= 0) {
      skipped.add(
        SkippedDeviceEntry(
          line: line,
          reason: 'one word, so it is not an ls -l row',
        ),
      );
      continue;
    }
    final modeMatch = _mode.firstMatch(line.substring(0, firstSpace));
    if (modeMatch == null) {
      skipped.add(
        SkippedDeviceEntry(
          line: line,
          reason: 'it does not begin with a permissions word',
        ),
      );
      continue;
    }
    final kind = DeviceEntryKind.fromModeChar(modeMatch.group(1)!);
    final mode = modeMatch.group(0)!;

    final timestamp = _timestamp.firstMatch(line);
    String? name;
    int? size;
    String? owner;
    String? group;
    String? modified;
    var readable = true;

    if (timestamp != null && timestamp.start > firstSpace) {
      modified = timestamp.group(0);
      name = line.substring(timestamp.end).trimLeft();
      // Everything between the mode and the timestamp: link count, owner,
      // group, size — in whatever number of columns this device uses.
      final middle = line
          .substring(firstSpace, timestamp.start)
          .trim()
          .split(RegExp(r'\s+'))
          .where((token) => token.isNotEmpty)
          .toList();
      // Not a size when a device node prints `1, 3` (major, minor) there, or
      // when an old toolbox prints nothing for a directory. Both come out null.
      final deviceNode =
          middle.length >= 2 && middle[middle.length - 2].endsWith(',');
      if (middle.isNotEmpty && !deviceNode) size = int.tryParse(middle.last);
      // Owner and group are the two columns before the size, when this device
      // printed a link count as well. Read from the right so a missing link
      // count does not shift them.
      final consumed = deviceNode ? 2 : (size == null ? 0 : 1);
      final named = middle.sublist(0, middle.length - consumed);
      if (named.length >= 2) {
        owner = named[named.length - 2];
        group = named[named.length - 1];
      }
    } else if (mode.contains('?')) {
      final match = _unstattable.firstMatch(line);
      if (match == null) {
        skipped.add(
          SkippedDeviceEntry(
            line: line,
            reason: 'the device could not stat it and printed no name',
          ),
        );
        continue;
      }
      name = match.group(1)!.trim();
      readable = false;
    } else {
      skipped.add(
        SkippedDeviceEntry(
          line: line,
          reason: 'no date column, so where the name begins is unknowable',
        ),
      );
      continue;
    }

    if (name.isEmpty) {
      skipped.add(SkippedDeviceEntry(line: line, reason: 'it names nothing'));
      continue;
    }

    String? linkTarget;
    if (kind == DeviceEntryKind.symlink) {
      // `name -> target`. Split at the first arrow: a target containing one is
      // the likelier of the two ambiguous cases, and ls escapes neither.
      final arrow = name.indexOf(' -> ');
      if (arrow >= 0) {
        linkTarget = name.substring(arrow + 4).trim();
        name = name.substring(0, arrow).trim();
        // What a device prints when it could not read the link either.
        if (linkTarget == '?') linkTarget = null;
      }
    }

    // `ls -a` includes both, and neither is an entry anybody wants to click.
    if (name == '.' || name == '..') continue;
    // Some devices print the argument rather than the bare name. The listing is
    // of one directory, so the basename is the only part about this row.
    final bare = name.contains('/') ? name.split('/').last : name;
    if (bare.isEmpty) continue;

    entries.add(
      DeviceFileEntry(
        path: devicePathJoin(directory, bare),
        name: bare,
        kind: kind,
        sizeBytes: size,
        modifiedLabel: modified,
        mode: mode,
        owner: owner,
        group: group,
        linkTarget: linkTarget,
        readable: readable,
      ),
    );
  }

  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return DeviceDirectoryListing(
    path: directory,
    entries: entries,
    skipped: skipped,
  );
}

/// Joins a device directory and a name, always with forward slashes. Not
/// `package:path`: on Windows that builds `\sdcard\DCIM`, which is no phone's.
String devicePathJoin(String directory, String name) {
  if (directory.isEmpty || directory == '/') return '/$name';
  final base = directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  return '$base/$name';
}

/// The parent of a device path, or null at the root.
String? devicePathParent(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  if (trimmed == '/' || trimmed.isEmpty) return null;
  final cut = trimmed.lastIndexOf('/');
  if (cut < 0) return null;
  return cut == 0 ? '/' : trimmed.substring(0, cut);
}

/// The last segment of a device path.
String devicePathBasename(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final cut = trimmed.lastIndexOf('/');
  return cut < 0 ? trimmed : trimmed.substring(cut + 1);
}

/// Bytes moved, out of the line `adb push`/`adb pull` prints when it is done.
///
/// ```
/// /sdcard/x.txt: 1 file pulled, 0 skipped. 0.0 MB/s (17 bytes in 0.011s)
/// ```
///
/// **That line arrives on stderr, with exit code 0.**
int? parseTransferredBytes(String output) {
  final match = RegExp(r'\((\d+)\s+bytes?\s+in\s').firstMatch(output);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Whether a `pull`/`push` actually moved something — adb's own words, because a
/// pull whose children were unreadable exits 0 having skipped them.
bool transferSucceeded(String output) =>
    RegExp(r'\d+\s+files?\s+(pulled|pushed)').hasMatch(output) &&
    !output.contains('adb: error:');

/// The human half of an adb failure, with adb's own `adb: error:` prefix taken
/// off: the sentence after the colon is what reads well in a dialog.
String cleanAdbError(String output) {
  final lines = [
    for (final line in output.split(RegExp(r'[\r\n]+')))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.isEmpty) return 'adb said nothing about why.';
  final error = lines.firstWhere(
    (line) => line.startsWith('adb: error:'),
    orElse: () => lines.last,
  );
  return error.replaceFirst(RegExp(r'^adb:\s*error:\s*'), '');
}
