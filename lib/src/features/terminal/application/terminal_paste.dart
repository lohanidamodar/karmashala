import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

/// What `Ctrl+V` sends when there is nothing to paste: the key itself.
const String kPasteKeyToProgram = '\x16';

/// Pastes the clipboard into [terminal], or hands `Ctrl+V` to the program.
///
/// **Why this is not xterm's paste.** Loop 84 bound `Ctrl+V` to xterm's own
/// `PasteTextIntent` action, which reads `text/plain` and nothing else. With a
/// screenshot on the clipboard that action pasted nothing *and* consumed the
/// key, so Claude Code — which reads the image off the clipboard itself when it
/// sees `^V` — never learned a paste had been asked for. The owner's report was
/// exactly that: "i was able to paste image before, now in this build i cannot
/// paste image in the terminal claude session".
///
/// So the app claims the chord only while it has something to paste. Text
/// pastes as before, bracketed where the program asked for it; with no text a
/// terminal paste could do nothing anyway, and the program gets its key back.
/// That is the whole rule, and it needs no way to read an image: an image on
/// the clipboard is precisely a clipboard with no text on it.
Future<void> pasteIntoTerminal(
  Terminal terminal, {
  TerminalController? controller,
}) async {
  // A clipboard read is not reliable on Windows: `OpenClipboard` fails while
  // another app holds it — a clipboard manager, a browser mid-copy, an RDP
  // session — and Flutter turns that into a `PlatformException`. Unhandled, it
  // left the chord doing *nothing at all*: no paste, and not even the `^V` the
  // fallback exists to send. A clipboard we cannot read is a clipboard with no
  // text on it, which is a case this function already answers.
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
