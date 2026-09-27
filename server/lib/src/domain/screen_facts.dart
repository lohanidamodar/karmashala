import 'package:karmashala_launch/karmashala_launch.dart'
    show workingDirectoryFromOsc;
import 'package:xterm2/core.dart';

/// One OSC 133 marker the shell wrote (`A`/`B`/`C`/`D`), where the cursor was
/// when it arrived — an absolute row of the screen and its scrollback — and,
/// for `D`, the exit code it carried (null when it carried none).
class ScreenMarker {
  const ScreenMarker(this.kind, this.row, this.column, {this.exitCode});

  final String kind;
  final int row;
  final int column;
  final int? exitCode;
}

/// Some lines of the screen: whether they really are the span asked for, and
/// how many were dropped from the head to honour a cap.
class ScreenSpan {
  const ScreenSpan({
    required this.lines,
    required this.scoped,
    this.omitted = 0,
  });

  static const ScreenSpan unscoped = ScreenSpan(
    lines: <String>[],
    scoped: false,
  );

  final List<String> lines;
  final bool scoped;
  final int omitted;
}

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

  /// How many commands the shell has said it runs (OSC 133 `C`): the id of
  /// the newest block, so a command run twice is two blocks.
  int commandCount = 0;

  /// Whether the newest command has ended (OSC 133 `D`, with or without a
  /// code). True before any command: nothing runs.
  bool lastCommandEnded = true;
  /// Whether the shell has ever written an OSC 133 marker here.
  bool markersSeen = false;

  /// Whether a command has started (`C`) and not yet ended (`D`).
  bool commandRunning = false;

  /// Told after each fact moves, in the same turn as the bytes that moved it.
  void Function()? onChanged;

  final _markerListeners = <void Function(ScreenMarker marker)>[];

  /// Tells [listener] of every OSC 133 marker from now on, in the same turn
  /// as the bytes that carried it (slice 5b: `terminal_run` waits on them).
  void addMarkerListener(void Function(ScreenMarker marker) listener) =>
      _markerListeners.add(listener);

  void removeMarkerListener(void Function(ScreenMarker marker) listener) =>
      _markerListeners.remove(listener);

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
    markersSeen = true;
    if (args.first == 'C') commandRunning = true;
    if (args.first == 'D') commandRunning = false;
    if (_markerListeners.isNotEmpty) {
      final marker = ScreenMarker(
        args.first,
        buffer.absoluteCursorY,
        buffer.cursorX,
        exitCode: args.first == 'D' && args.length > 1
            ? int.tryParse(args[1])
            : null,
      );
      for (final listener in List.of(_markerListeners)) {
        listener(marker);
      }
    }
    switch (args.first) {
      case 'B':
        _commandStart = (buffer.absoluteCursorY, buffer.cursorX);
      case 'C':
        final command = _commandSince(_commandStart);
        _commandStart = null;
        if (command == null || command.isEmpty) return;
        lastCommand = command;
        lastCommandExitCode = null;
        commandCount++;
        lastCommandEnded = false;
        onChanged?.call();
      case 'D':
        final code = args.length > 1 ? int.tryParse(args[1]) : null;
        if (lastCommand == null ||
            (lastCommandEnded && code == lastCommandExitCode)) {
          return;
        }
        lastCommandExitCode = code;
        lastCommandEnded = true;
        onChanged?.call();
    }
  }

  /// The text between [from] (a marker's row and column) and [to] — or the
  /// end of the buffer while nothing ended it — trailing blank rows dropped,
  /// at most [maxLines] kept from the tail. Unscoped when [from] has already
  /// scrolled out of the buffer: nobody else's lines are handed back instead.
  ScreenSpan span((int, int) from, {(int, int)? to, int maxLines = 200}) {
    final lines = _screen.buffer.lines;
    final (startRow, startColumn) = from;
    if (startRow < 0 || startRow >= lines.length) return ScreenSpan.unscoped;
    final endRow = to?.$1;
    final endColumn = to?.$2;
    var last = endRow ?? lines.length - 1;
    if (last >= lines.length) last = lines.length - 1;
    if (last < startRow) return ScreenSpan.unscoped;
    bool blank(int y, int? upTo) {
      final line = lines[y];
      final end = upTo == null || upTo > line.length ? line.length : upTo;
      for (var i = 0; i < end; i++) {
        if (line.getCodePoint(i) > 32) return false;
      }
      return true;
    }

    while (last > startRow && blank(last, last == endRow ? endColumn : null)) {
      last--;
    }
    final total = last - startRow + 1;
    final omitted = total > maxLines ? total - maxLines : 0;
    final out = <String>[];
    for (var y = startRow + omitted; y <= last; y++) {
      final line = lines[y];
      final begin = y == startRow ? startColumn : 0;
      final upTo = y == endRow ? endColumn : null;
      final end = upTo == null || upTo > line.length ? line.length : upTo;
      final text = StringBuffer();
      for (var i = begin; i < end; i++) {
        final code = line.getCodePoint(i);
        text.writeCharCode(code == 0 ? 32 : code);
      }
      out.add(text.toString().trimRight());
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return ScreenSpan(lines: out, scoped: true, omitted: omitted);
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
      text.write(row == fromRow ? line.getText(fromColumn) : line.getText());
    }
    return text.toString().trim();
  }
}
