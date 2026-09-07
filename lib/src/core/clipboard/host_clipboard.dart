/// This computer's clipboard, behind a seam.
///
/// Two reasons it is not `Clipboard` called directly:
///
/// 1. **A clipboard read fails on Windows and it is not exceptional.**
///    `OpenClipboard` refuses while another process holds it — a clipboard
///    manager, a browser mid-copy, an RDP session — and Flutter turns that into
///    a `PlatformException`. `terminal/application/terminal_paste.dart` learned
///    this the hard way: unhandled, the paste chord did nothing at all. Every
///    read here is guarded once, in one place.
/// 2. **Nothing in a test may reach the platform channel.** The device
///    clipboard bridge and the device file browser both move user data through
///    this, and both are tested.
///
/// The *file* half exists because a file clipboard is a different thing from a
/// text clipboard on every desktop: Explorer puts `CF_HDROP` on the board, not
/// a list of paths as text. `pasteboard` is already a dependency and
/// `pasteboard_plugin.dll` already ships in the installer, so this is a seam
/// over something the app can already do rather than a new capability.
library;

import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

/// What a clipboard read produced, keeping "nothing there" apart from "could
/// not look".
///
/// The same three-valued shape as `DeviceClipboardRead`, and for the same
/// reason (§19): a clipboard that refused to open is not an empty clipboard,
/// and telling the user to copy something again is the wrong instruction.
enum HostClipboardOutcome { text, empty, unavailable }

/// One reading of this computer's clipboard.
class HostClipboardRead {
  const HostClipboardRead._(this.outcome, {this.text, this.reason});

  factory HostClipboardRead.text(String text) => text.isEmpty
      ? const HostClipboardRead._(HostClipboardOutcome.empty)
      : HostClipboardRead._(HostClipboardOutcome.text, text: text);

  const HostClipboardRead.empty()
    : this._(HostClipboardOutcome.empty);

  const HostClipboardRead.unavailable(String reason)
    : this._(HostClipboardOutcome.unavailable, reason: reason);

  final HostClipboardOutcome outcome;

  /// Non-null exactly when [outcome] is [HostClipboardOutcome.text].
  /// **User data**: not logged, not put in an error message.
  final String? text;

  /// Non-null exactly when [outcome] is [HostClipboardOutcome.unavailable].
  final String? reason;

  bool get hasText => outcome == HostClipboardOutcome.text;
}

/// Reading and writing this computer's clipboard.
abstract interface class HostClipboard {
  Future<HostClipboardRead> readText();

  Future<void> writeText(String text);

  /// Paths of the files on the clipboard, empty when there are none.
  ///
  /// Empty and "could not look" are **not** separated here, deliberately: this
  /// one is only ever read in answer to the user pressing Paste, so an empty
  /// answer is reported as "no files on the clipboard" at the call site, which
  /// is a true statement either way. Nothing decides anything else from it.
  Future<List<String>> readFiles();

  /// Puts [paths] on the clipboard as files, so they can be pasted into a file
  /// manager. Returns whether the platform accepted them.
  Future<bool> writeFiles(List<String> paths);
}

/// The real thing: Flutter's text clipboard and `pasteboard`'s file clipboard.
class PlatformHostClipboard implements HostClipboard {
  const PlatformHostClipboard();

  @override
  Future<HostClipboardRead> readText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null) return const HostClipboardRead.empty();
      return HostClipboardRead.text(text);
    } on PlatformException catch (error) {
      // The message, not the text — there is no clipboard content in a
      // PlatformException from a failed OpenClipboard.
      return HostClipboardRead.unavailable(
        'This computer would not open its clipboard: '
        '${error.message ?? error.code}. Something else is holding it — a '
        'clipboard manager, or a copy in progress. Try again.',
      );
    } on MissingPluginException {
      return const HostClipboardRead.unavailable(
        'This build has no clipboard plugin.',
      );
    }
  }

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<List<String>> readFiles() async {
    try {
      return await Pasteboard.files();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<bool> writeFiles(List<String> paths) async {
    if (paths.isEmpty) return false;
    try {
      return await Pasteboard.writeFiles(paths);
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
