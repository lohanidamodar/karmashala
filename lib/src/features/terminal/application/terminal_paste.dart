import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

/// What `Ctrl+V` sends when there is nothing to paste: the key itself.
const String kPasteKeyToProgram = '\x16';

/// Pastes the clipboard into [terminal], or hands `Ctrl+V` to the program:
/// xterm's own paste reads `text/plain`, so it ate the key on an image.
Future<void> pasteIntoTerminal(
  Terminal terminal, {
  TerminalController? controller,
}) async {
  // On Windows `OpenClipboard` fails while another app holds it and Flutter
  // raises; unhandled, the chord did nothing at all, not even send `^V`.
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
