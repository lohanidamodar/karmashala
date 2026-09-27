import 'package:karmashala_launch/karmashala_launch.dart'
    show workingDirectoryFromOsc;
import 'package:xterm2/core.dart';

/// What a program has told its terminal about itself, read off the host's own
/// copy of the screen (slice 5a) — so every client, and none, sees the same:
/// the title it set (OSC 0/2), the directory its shell is in (OSC 7), and the
/// last command the shell ran and how it ended (OSC 133 `B`/`C`/`D`).
class ScreenFacts {
  ScreenFacts(this._screen, {this.hostname});

  final Terminal _screen;

  /// This machine's name, so an OSC 7 from another host is not taken for a
  /// directory here.
  final String? hostname;

  String? title;
  String? workingDirectory;
  String? lastCommand;
  int? lastCommandExitCode;

  /// Told after each fact moves, in the same turn as the bytes that moved it.
  void Function()? onChanged;

  /// Where the command line began (OSC 133 `B`): absolute row, column.
  (int, int)? _commandStart;

  void titleChanged(String value) {
    if (value == title) return;
    title = value;
    onChanged?.call();
  }

  void directoryChanged(String uri) => osc('7', [uri]);

  void osc(String code, List<String> args) {
    if (code == '7') {
      final directory = workingDirectoryFromOsc(code, args, hostname: hostname);
      if (directory == null || directory == workingDirectory) return;
      workingDirectory = directory;
      onChanged?.call();
      return;
    }
    if (code != '133' || args.isEmpty) return;
    final buffer = _screen.buffer;
    switch (args.first) {
      case 'B':
        _commandStart = (buffer.absoluteCursorY, buffer.cursorX);
      case 'C':
        final command = _commandSince(_commandStart);
        _commandStart = null;
        if (command == null || command.isEmpty) return;
        lastCommand = command;
        lastCommandExitCode = null;
        onChanged?.call();
      case 'D':
        final code = args.length > 1 ? int.tryParse(args[1]) : null;
        if (lastCommand == null || code == lastCommandExitCode) return;
        lastCommandExitCode = code;
        onChanged?.call();
    }
  }

  /// The text typed between the prompt's end and the cursor now: the command
  /// the shell is about to run, across wrapped rows. Null when the rows it
  /// began on have scrolled out of the buffer.
  String? _commandSince((int, int)? start) {
    if (start == null) return null;
    final lines = _screen.buffer.lines;
    final (fromRow, fromColumn) = start;
    final toRow = _screen.buffer.absoluteCursorY;
    if (fromRow < 0 || fromRow >= lines.length || toRow < fromRow) return null;
    final text = StringBuffer();
    for (var row = fromRow; row <= toRow && row < lines.length; row++) {
      final line = lines[row];
      text.write(
        row == fromRow ? line.getText(fromColumn) : line.getText(),
      );
    }
    return text.toString().trim();
  }
}
