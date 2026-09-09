/// Paths cut or copied in a device's file browser, waiting to be pasted.
///
/// ## Why this is not `List<String>`
///
/// A pasteboard of paths has to remember three things beyond the paths, and
/// each of them is a refusal the user would otherwise meet as a shell error:
///
/// * **Which device they live on.** Two devices can be attached, and
///   `/sdcard/DCIM/a.jpg` exists on both. Pasting one device's paths into
///   another is not a `cp` at all — it is a pull followed by a push, a
///   different operation with a different cost — so it is refused by name
///   rather than run against the wrong phone.
/// * **Copy or cut**, because a cut that is pasted twice must not move a file
///   that is no longer there. [afterPaste] answers that.
/// * **What the entries were**, not just where. A directory needs `cp -r`, and
///   whether a paste into its own subtree is legal is a question about the
///   source's kind.
library;

import 'device_files.dart';

/// Whether pasting copies or moves.
enum DeviceFileClipboardMode {
  copy('Copy'),
  cut('Cut');

  const DeviceFileClipboardMode(this.label);

  final String label;

  bool get isCut => this == DeviceFileClipboardMode.cut;
}

/// One or more device paths on the app's own pasteboard.
///
/// Deliberately **not** the system clipboard. A device path is meaningless to
/// every other program on this computer, and putting `/sdcard/DCIM/a.jpg` on
/// the Windows clipboard as text would silently replace whatever the user had
/// copied with a string nothing can open. Moving a device file to this
/// computer's clipboard is a different operation — it stages a real file first
/// — and lives in `device_file_staging.dart`.
class DeviceFileClipboard {
  const DeviceFileClipboard({
    required this.serial,
    required this.entries,
    required this.mode,
  });

  /// The device the paths are on.
  final String serial;

  final List<DeviceFileEntry> entries;
  final DeviceFileClipboardMode mode;

  bool get isEmpty => entries.isEmpty;

  /// One line for a toolbar: what is held and what pasting will do.
  String get summary =>
      '${mode.label} ${entries.length == 1 ? entries.single.name : '${entries.length} items'}';

  /// Why these cannot be pasted into [directory] on [intoSerial], or null when
  /// they can.
  ///
  /// Checked before anything runs, because every one of these is a mistake the
  /// device would answer with a half-finished tree or a shell diagnostic.
  String? refusalFor({required String intoSerial, required String directory}) {
    if (isEmpty) return 'There is nothing on the clipboard to paste.';
    if (intoSerial != serial) {
      return 'Those paths are on $serial and this is $intoSerial. Copying '
          'between two devices is a pull followed by a push, not a paste — '
          'save the file to this computer first, then add it here.';
    }
    for (final entry in entries) {
      if (entry.path == devicePathIn(directory, entry.name)) {
        return '${entry.name} is already in $directory.';
      }
      if (entry.isDirectory &&
          _isInside(directory: directory, under: entry.path)) {
        return 'You are pasting ${entry.name} into itself. That does not '
            'terminate on the device, so nothing was done.';
      }
    }
    return null;
  }

  /// What the clipboard should be after a successful paste.
  ///
  /// A **cut is consumed**: the files are somewhere else now, and a second
  /// paste of the same cut would try to move paths that no longer exist and
  /// report a device fault for the app's own bookkeeping. A copy survives, so
  /// one copy can be pasted into several folders — which is what every file
  /// manager does and what a user expects.
  DeviceFileClipboard? afterPaste() => mode.isCut ? null : this;

  static bool _isInside({required String directory, required String under}) {
    final prefix = under.endsWith('/') ? under : '$under/';
    return directory == under || directory.startsWith(prefix);
  }
}

/// [directory] and [name] joined as a device path.
///
/// Its own function here rather than `devicePathJoin` from the data layer: the
/// domain must not depend on the adb parser, and this is the only path
/// arithmetic the clipboard needs.
String devicePathIn(String directory, String name) =>
    directory.endsWith('/') ? '$directory$name' : '$directory/$name';
