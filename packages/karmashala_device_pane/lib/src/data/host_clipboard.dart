/// This computer's clipboard, the platform's own: Flutter's text clipboard and
/// `pasteboard`'s file clipboard behind `karmashala_devices`' `HostClipboard`.
library;

import 'package:flutter/services.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:pasteboard/pasteboard.dart';

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
