/// Reaching a device's storage: what a driver can see, and what it refuses.
///
/// ## Roots, not "the filesystem"
///
/// The obvious shape for this — one tree starting at `/` — is a shape only
/// Android can honour, and even there it is half true. The two platforms this
/// app drives disagree about what a device's storage *is*:
///
/// * **Android** has a real filesystem from `/`, but the interesting half of it
///   is closed: almost nothing under `/data` is readable as the shell user, and
///   an app's own directory is reachable only through `run-as` on a debuggable
///   build.
/// * **A real iOS device** has no browsable root at all. What is exposed to a
///   development machine is the *container* of each development-signed app, one
///   sandbox at a time — there is nothing to show above them.
/// * **An iOS Simulator** is neither: it is a directory on the host Mac, and
///   the honest root there is a host path, not a device path.
///
/// An interface that promised `/` would force the iOS driver to invent one. So
/// a driver answers with the *places it can reach* — [DeviceFileRoot]s — and a
/// caller navigates from those. That is the part of this file meant to outlive
/// the Android implementation underneath it.
library;

/// What kind of thing one entry in a device directory is.
///
/// [symlink] is its own kind rather than resolved away, because on Android the
/// interesting paths are symlinks — `/sdcard` is one, and so is every one of
/// `/bin`, `/etc` and `/d` — and a browser that silently followed them would
/// show a user a path they cannot type back.
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

  final String name;
  final DeviceEntryKind kind;

  /// Size in bytes, or null when the device would not say — a directory on an
  /// old toolbox `ls`, or a device node, whose size column is `major, minor`.
  final int? sizeBytes;

  /// The timestamp **exactly as the device printed it**, and deliberately not a
  /// `DateTime`.
  ///
  /// `ls` prints the device's own local time with no zone on it, and in two
  /// formats — `2026-09-03 18:52` from toybox, `Sep  3 18:52` from busybox,
  /// the second of which omits the year for anything recent. Turning either
  /// into a `DateTime` means choosing a zone the device never stated and, for
  /// the second, a year it never printed. A label cannot be wrong about a
  /// timezone.
  final String? modifiedLabel;

  /// The `ls` mode word, verbatim: `drwxrwx---`. Shown rather than decoded —
  /// this is a developer's tool and the string is the thing they know.
  final String? mode;

  final String? owner;
  final String? group;

  /// Where a [DeviceEntryKind.symlink] points, or null when the device could
  /// not read the link either.
  final String? linkTarget;

  /// False when the device listed the entry but could not stat it.
  ///
  /// Not hypothetical: the owner's own handset prints
  /// `d?????????   ? ?  ?  ?  ? data_mirror` at `/`, and half a dozen rows like
  /// it. The name is real, the metadata is not, and *hiding* the row would be
  /// the wrong answer twice over — it exists, and the reason it cannot be read
  /// is the interesting part.
  final bool readable;

  bool get isDirectory => kind == DeviceEntryKind.directory;

  @override
  String toString() => 'DeviceFileEntry($path, ${kind.name})';
}

/// A line of device output that could not be turned into an entry, kept with
/// the reason it could not.
///
/// The point of the type: `ls` output varies by device, by Android version and
/// by which of toybox, toolbox or busybox is behind it, and a parser that meets
/// a shape it does not know has exactly three options — crash, invent a row, or
/// say so. Only the third is usable, and it is only usable if the reason
/// travels with it.
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

  /// Sorted directories first, then by name — the order a file browser is
  /// expected to be in, decided here so the pane and the MCP tool cannot
  /// disagree about it.
  final List<DeviceFileEntry> entries;

  /// Rows the device printed that this build could not read. Empty is the
  /// normal case; anything here is meant to be *shown*, not logged.
  final List<SkippedDeviceEntry> skipped;

  /// Anything the caller should know about how this listing was obtained.
  final String? note;

  bool get isEmpty => entries.isEmpty;
}

/// A place on a device this app can actually reach, and what it costs.
///
/// See the library comment for why a driver answers with a list of these
/// instead of a single filesystem root.
class DeviceFileRoot {
  const DeviceFileRoot({
    required this.path,
    required this.label,
    required this.description,
    required this.writable,
  });

  /// The path to list. On Android a device path; on an iOS Simulator this
  /// would be a **host** path, which is exactly why the type carries a
  /// description rather than assuming the caller knows what kind of path it
  /// is holding.
  final String path;

  /// What to call it in a picker.
  final String label;

  /// One sentence: what lives here, and what will be refused. Shown to the
  /// user, so it is written for them and not for a log.
  final String description;

  /// Whether a push or a delete has a chance here. False is a fact about the
  /// root, not a policy — `/` on a non-rooted device is read-only to adb no
  /// matter what the app would like.
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
/// and the pane's disabled control cannot drift apart.
///
/// ## What a later implementation would do, so the next person is not guessing
///
/// **An iOS Simulator** is the easy half and is not a device path problem at
/// all: its data lives in a directory on the host Mac,
/// `~/Library/Developer/CoreSimulator/Devices/<udid>/data`, and one app's
/// sandbox is `simctl get_app_container <udid> <bundleId> data`. A driver could
/// answer [DeviceFileRoot]s pointing at those host paths and then use ordinary
/// `dart:io` — no `pull` and no `push`, because a "transfer" there is a file
/// copy. That is why [DeviceFileRoot.path] is documented as possibly being a
/// host path: the shape already allows it.
///
/// **A real iPhone** is the hard half, and the shape is the reason this file
/// exists. There is no browsable root: what is exposed over usbmuxd's AFC
/// service is `/var/mobile/Media` (the camera roll and iTunes file sharing),
/// plus the *container* of each development-signed app through
/// `house_arrest`. Both need a usbmuxd client — `pymobiledevice3` or
/// `libimobiledevice`'s `afcclient` — which this app does not ship, and neither
/// is available on Windows without extra drivers. A driver that had one would
/// answer one [DeviceFileRoot] per reachable app container plus the media
/// directory, and every one of them would be [DeviceFileRoot.writable] only
/// where AFC says so.
const String kIosFileAccessUnsupported =
    'This build cannot browse an iOS device\'s files. A real iPhone exposes no '
    'browsable filesystem at all — only the container of each '
    'development-signed app, over a usbmuxd service this app does not ship a '
    'client for (pymobiledevice3, libimobiledevice). A Simulator could be '
    'browsed as a directory on this Mac and is simply not implemented yet. '
    'Everything else on this device still works: screenshots, the element '
    'tree, input, install and launch.';
