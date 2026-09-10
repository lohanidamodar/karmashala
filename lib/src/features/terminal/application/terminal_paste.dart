import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

/// What `Ctrl+V` sends when there is nothing to paste: the key itself.
const String kPasteKeyToProgram = '\x16';

/// Pastes the clipboard into [terminal], or hands `Ctrl+V` to the program.
///
/// **Not xterm's paste**: its `PasteTextIntent` reads `text/plain` only, so a
/// screenshot on the clipboard pasted nothing *and* consumed the key, and an
/// agent CLI that reads the image itself on `^V` never learned a paste was
/// asked for. The chord is claimed only when there is text — which needs no way
/// to read an image, since an image is a clipboard with no text on it.
Future<void> pasteIntoTerminal(
  Terminal terminal, {
  TerminalController? controller,
}) async {
  // On Windows `OpenClipboard` fails while another app holds it — a clipboard
  // manager, a browser mid-copy, RDP — and Flutter raises a
  // `PlatformException`. Unhandled, the chord then did nothing at all, not even
  // send `^V`. Unreadable is treated as "no text", which is already answered.
  String? text;
  try {
    text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } on PlatformException {
    text = null;
  }
  if (text == null || text.isEmpty) {
    terminal.textInput(kPasteKeyToProgram);
    return;
  }
  terminal.paste(text);
  controller?.clearSelection();
}
