/// Reaching a device's storage: what a driver can see, and what it refuses.
///
/// A driver answers with the *places it can reach* — [DeviceFileRoot]s — rather
/// than one tree from `/`, because only Android has one: a real iOS device
/// exposes one app container at a time, and a simulator is a host directory.
library;

/// What kind of thing one entry in a device directory is. [symlink] is its own
/// kind: `/sdcard` is one, and following it shows a path the user cannot type.
enum DeviceEntryKind {
  file,
  directory,
  symlink,

  /// A socket, a fifo, or a device node. Listed rather than hidden: `/dev` is
  /// full of them and an entry missing from a listing reads as a listing that
  /// failed.
  other;

  /// The first character of an `ls -l` mode word, which is where every Unix
  /// says this.
  static DeviceEntryKind fromModeChar(String character) => switch (character) {
    'd' => DeviceEntryKind.directory,
    'l' => DeviceEntryKind.symlink,
    '-' => DeviceEntryKind.file,
    _ => DeviceEntryKind.other,
  };
}

/// One entry in a device directory.
class DeviceFileEntry {
  const DeviceFileEntry({
    required this.path,
    required this.name,
    required this.kind,
    this.sizeBytes,
    this.modifiedLabel,
    this.mode,
    this.owner,
    this.group,
    this.linkTarget,
    this.readable = true,
  });

  /// Absolute path **on the device**.
  final String path;

  /// A dot-file, the only hidden convention Android has.
  bool get isHidden => name.startsWith('.');

  final String name;
  final DeviceEntryKind kind;

  /// Size in bytes, or null when the device would not say — a directory on an
  /// old toolbox `ls`, or a device node, whose size column is `major, minor`.
  final int? sizeBytes;

  /// The timestamp **exactly as the device printed it**, and deliberately not a
  /// `DateTime`: `ls` states no zone, and busybox omits the year.
  final String? modifiedLabel;

  /// The `ls` mode word, verbatim: `drwxrwx---`. Shown rather than decoded —
  /// this is a developer's tool and the string is the thing they know.
  final String? mode;

  final String? owner;
  final String? group;

  /// Where a [DeviceEntryKind.symlink] points, or null when the device could
  /// not read the link either.
  final String? linkTarget;

  /// False when the device listed the entry but could not stat it — the owner's
  /// handset does this at `/`. The name is real; hiding the row hides both.
  final bool readable;

  bool get isDirectory => kind == DeviceEntryKind.directory;

  @override
  String toString() => 'DeviceFileEntry($path, ${kind.name})';
}

/// A line of device output that could not be turned into an entry, kept with the
/// reason. A parser meeting an unknown shape can crash, invent a row, or say so.
class SkippedDeviceEntry {
  const SkippedDeviceEntry({required this.line, required this.reason});

  final String line;
  final String reason;

  @override
  String toString() => 'SkippedDeviceEntry($line: $reason)';
}

/// One directory, as far as it could be read.
class DeviceDirectoryListing {
  const DeviceDirectoryListing({
    required this.path,
    required this.entries,
    this.skipped = const [],
    this.note,
  });

  /// The directory this is a listing *of*, on the device.
  final String path;

  /// Sorted directories first, then by name, decided here so the pane and the
  /// MCP tool cannot disagree about it.
  final List<DeviceFileEntry> entries;

  /// Rows the device printed that this build could not read. Empty is the
  /// normal case; anything here is meant to be *shown*, not logged.
  final List<SkippedDeviceEntry> skipped;

  /// Anything the caller should know about how this listing was obtained.
  final String? note;

  bool get isEmpty => entries.isEmpty;
}

/// A place on a device this app can actually reach, and what it costs. See the
/// library comment for why a driver answers with a list of these.
class DeviceFileRoot {
  const DeviceFileRoot({
    required this.path,
    required this.label,
    required this.description,
    required this.writable,
  });

  /// The path to list: a device path on Android, a **host** path on an iOS
  /// Simulator — which is why the type carries a description of its own.
  final String path;

  /// What to call it in a picker.
  final String label;

  /// One sentence: what lives here, and what will be refused. Shown to the
  /// user, so it is written for them and not for a log.
  final String description;

  /// Whether a push or a delete has a chance here. A fact about the root: `/` on
  /// a non-rooted device is read-only to adb whatever the app would like.
  final bool writable;

  @override
  String toString() => 'DeviceFileRoot($path)';
}

/// What a completed transfer moved.
class DeviceFileTransfer {
  const DeviceFileTransfer({
    required this.devicePath,
    required this.hostPath,
    this.bytes,
    this.note,
  });

  final String devicePath;

  /// Where it landed on, or came from, this computer.
  final String hostPath;

  /// Bytes moved, when the tool reported a number.
  final int? bytes;

  /// Anything the caller should know — that a destination directory decided
  /// the final name, for instance.
  final String? note;
}

/// Why iOS has no file access in this build, said once so the driver's refusal
/// and the pane's disabled control cannot drift apart. A simulator's data is a
/// host directory and needs no transport; a real iPhone needs a usbmuxd client
/// for AFC and `house_arrest`, which this app does not ship.
const String kIosFileAccessUnsupported =
    'This build cannot browse an iOS device\'s files. A real iPhone exposes no '
    'browsable filesystem at all — only the container of each '
    'development-signed app, over a usbmuxd service this app does not ship a '
    'client for (pymobiledevice3, libimobiledevice). A Simulator could be '
    'browsed as a directory on this Mac and is simply not implemented yet. '
    'Everything else on this device still works: screenshots, the element '
    'tree, input, install and launch.';
