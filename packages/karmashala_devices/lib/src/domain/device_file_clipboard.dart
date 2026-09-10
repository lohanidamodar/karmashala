/// Paths cut or copied in a device's file browser, waiting to be pasted.
///
/// Not `List<String>`: it has to remember which device they live on (the same
/// path exists on both), whether this was a copy or a cut (a cut pasted twice
/// must not move a file that has gone), and what the entries were (a directory
/// needs `cp -r`). Each of those is a refusal the user would otherwise meet as
/// a shell error.
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

/// One or more device paths on the app's own pasteboard. Deliberately **not**
/// the system clipboard: a device path is meaningless to every other program,
/// and writing one there replaces whatever the user had copied.
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
  /// they can. Checked before anything runs: the device would answer each of
  /// them with a half-finished tree or a shell diagnostic.
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

  /// What the clipboard should be after a successful paste. A **cut is
  /// consumed** — a second paste would move paths that no longer exist — while a
  /// copy survives, so one copy can go into several folders.
  DeviceFileClipboard? afterPaste() => mode.isCut ? null : this;

  static bool _isInside({required String directory, required String under}) {
    final prefix = under.endsWith('/') ? under : '$under/';
    return directory == under || directory.startsWith(prefix);
  }
}

/// [directory] and [name] joined as a device path. Its own function because the
/// domain must not depend on the adb parser.
String devicePathIn(String directory, String name) =>
    directory.endsWith('/') ? '$directory$name' : '$directory/$name';
