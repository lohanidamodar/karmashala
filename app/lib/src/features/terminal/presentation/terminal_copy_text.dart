import 'package:xterm2/xterm.dart';

/// What a copy of [selection] puts on the clipboard, for every way a pane
/// copies: the chord, the menu's Copy and Ctrl+C. Each line loses its trailing
/// blanks, as xterm's own copy action and a native terminal's do; the menu and
/// Ctrl+C once kept them, and pasted every row padded out with spaces.
String terminalCopyText(Buffer buffer, BufferRange selection) =>
    buffer.getText(selection, true);
