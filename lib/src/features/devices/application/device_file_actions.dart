/// The file-browser actions that move things, kept out of the widget.
///
/// Each one is several awaited device calls with a refusal at every step, and
/// each has to end in a sentence the user can act on. Written here so those
/// sentences are testable without a phone and without pumping a dialog — the
/// pane keeps only navigation state, which is the part a widget is good at.
///
/// **Every host path built from a device id goes through
/// `deviceStagedFilePath`**, which goes through `DeviceTarget.fileSafeId`. That
/// is the whole reason [copyToHostClipboard] does not join a path itself: see
/// `device_file_staging.dart` for what a colon in a Windows filename does
/// instead of failing.
library;

import 'dart:io';

import '../../../core/clipboard/host_clipboard.dart';
import 'package:karmashala_devices/karmashala_devices.dart';

/// Creates a host directory. Injected so a test never writes to a real disk.
typedef HostDirectoryMaker = Future<void> Function(String path);

/// The real one: creates [path] and every missing parent.
Future<void> makeHostDirectory(String path) =>
    Directory(path).create(recursive: true).then((_) {});

/// What one action did, and whether the listing has to be read again.
class DeviceFileActionReport {
  const DeviceFileActionReport(this.message, {this.deviceChanged = false});

  /// One line for the user. Never a stack trace and never file *contents*.
  final String message;

  /// Whether anything on the device moved, so the open directory is now stale.
  /// False for a refusal, which is exactly when re-listing would be a wasted
  /// subprocess.
  final bool deviceChanged;
}

/// Pastes [clip] into [directory] on the device [driver] drives.
///
/// One device call per entry plus its checks, and it **stops at the first
/// refusal** rather than carrying on through the rest: a partial paste that
/// reported only its last result is how a user comes to believe six files
/// moved when two did. What did move is named.
Future<DeviceFileActionReport> pasteOnDevice({
  required DeviceDriver driver,
  required DeviceFileClipboard clip,
  required String directory,
  bool overwrite = false,
}) async {
  final refusal = clip.refusalFor(
    intoSerial: driver.target.id,
    directory: directory,
  );
  if (refusal != null) return DeviceFileActionReport(refusal);

  final done = <String>[];
  for (final entry in clip.entries) {
    try {
      await driver.copyWithinDevice(
        from: entry.path,
        to: devicePathIn(directory, entry.name),
        move: clip.mode.isCut,
        overwrite: overwrite,
      );
      done.add(entry.name);
    } on DeviceRefusal catch (error) {
      return DeviceFileActionReport(
        done.isEmpty
            ? '$error'
            : '${_verbPast(clip)} ${done.join(', ')}, then stopped: $error',
        deviceChanged: done.isNotEmpty,
      );
    }
  }
  return DeviceFileActionReport(
    '${_verbPast(clip)} ${done.join(', ')} into $directory.',
    deviceChanged: true,
  );
}

String _verbPast(DeviceFileClipboard clip) => clip.mode.isCut
    ? 'Moved'
    : 'Copied';

/// Copies [entries] off the device and puts them on **this computer's** file
/// clipboard, so they can be pasted into a file manager.
///
/// Two steps, and the first is the one that can be misread: a file clipboard
/// holds paths, so there has to be a real file on this disk before the
/// clipboard can name it. The staging directory is under the system temp
/// directory and its name is the device's `fileSafeId` — never its raw id.
///
/// Directories are refused rather than pulled: `pullFile` copies one file, and
/// silently walking a tree because a click landed on a folder is not a favour.
Future<DeviceFileActionReport> copyToHostClipboard({
  required DeviceDriver driver,
  required HostClipboard host,
  required String temporaryDirectory,
  required List<DeviceFileEntry> entries,
  HostDirectoryMaker makeDirectory = makeHostDirectory,
}) async {
  if (entries.isEmpty) {
    return const DeviceFileActionReport('Nothing was selected to copy.');
  }
  final directories = entries.where((entry) => entry.isDirectory).toList();
  if (directories.isNotEmpty) {
    return DeviceFileActionReport(
      '${directories.first.name} is a directory. This copies one file at a '
      'time; open it and pick a file.',
    );
  }
  final staging = deviceStagingDirectory(
    target: driver.target,
    temporaryDirectory: temporaryDirectory,
  );
  await makeDirectory(staging);
  final staged = <String>[];
  for (final entry in entries) {
    final hostPath = deviceStagedFilePath(
      target: driver.target,
      temporaryDirectory: temporaryDirectory,
      name: entry.name,
    );
    try {
      final moved = await driver.pullFile(
        devicePath: entry.path,
        hostPath: hostPath,
      );
      staged.add(moved.hostPath);
    } on DeviceRefusal catch (error) {
      return DeviceFileActionReport(
        staged.isEmpty
            ? '$error'
            : 'Copied ${staged.length} of ${entries.length}, then stopped: '
                  '$error',
      );
    }
  }
  final accepted = await host.writeFiles(staged);
  if (!accepted) {
    // The files are real and on this disk; only the clipboard refused. Saying
    // where they are is more use than saying the copy failed, because it did
    // not.
    return DeviceFileActionReport(
      'This computer would not take the files onto its clipboard. They are in '
      '$staging, so they can still be opened from there.',
    );
  }
  return DeviceFileActionReport(
    staged.length == 1
        ? 'Copied ${entries.single.name} — paste it anywhere on this computer.'
        : 'Copied ${staged.length} files — paste them anywhere on this '
              'computer.',
  );
}

/// Pushes whatever files are on **this computer's** clipboard into [directory]
/// on the device.
///
/// The other half of [copyToHostClipboard]: copy in Explorer, paste here.
/// An empty clipboard is reported as an empty clipboard and not as a failure,
/// because that is what it is — and the message says *file* clipboard, since
/// the usual reason is that what was copied was text.
Future<DeviceFileActionReport> pasteFromHostClipboard({
  required DeviceDriver driver,
  required HostClipboard host,
  required String directory,
  bool overwrite = false,
}) async {
  final files = await host.readFiles();
  if (files.isEmpty) {
    return const DeviceFileActionReport(
      'There are no files on this computer\'s clipboard. Copy a file in '
      'Explorer or Finder first — copied *text* does not paste as a file.',
    );
  }
  final done = <String>[];
  for (final file in files) {
    try {
      final moved = await driver.pushFile(
        hostPath: file,
        devicePath: directory,
        overwrite: overwrite,
      );
      done.add(devicePathBasenameOf(moved.devicePath));
    } on DeviceRefusal catch (error) {
      return DeviceFileActionReport(
        done.isEmpty
            ? '$error'
            : 'Copied ${done.join(', ')}, then stopped: $error',
        deviceChanged: done.isNotEmpty,
      );
    }
  }
  return DeviceFileActionReport(
    'Copied ${done.join(', ')} to $directory.',
    deviceChanged: true,
  );
}

/// The last segment of a device path.
///
/// Its own one-liner rather than the adb parser's `devicePathBasename`, which
/// this layer must not reach into — and it is only ever applied to a path the
/// driver just returned.
String devicePathBasenameOf(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 || cut == path.length - 1 ? path : path.substring(cut + 1);
}
