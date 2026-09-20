import 'package:xterm2/xterm.dart';

/// Writes retained history into [terminal] with its reply channel unplugged.
///
/// The emulator answers DSR/DA queries in what it parses, and on a replay that
/// answer would go to the *live* process as typing at its prompt. Every caller
/// happens to attach `onOutput` after replaying; this is what keeps that
/// ordering from being the only thing standing between a user and `^[[?1;2c`.
void replayScrollback(Terminal terminal, String scrollback) {
  final sink = terminal.onOutput;
  terminal.onOutput = null;
  try {
    terminal.write(scrollback);
  } finally {
    terminal.onOutput = sink;
  }
}
