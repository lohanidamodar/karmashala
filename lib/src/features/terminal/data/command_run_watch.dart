import 'dart:async';

import 'package:xterm2/xterm.dart';

import '../domain/command_blocks.dart';
import 'command_block_recorder.dart';
import 'terminal_instance.dart';

/// How many lines of one command's output are read back by default.
///
/// A cap rather than the whole region because a command can print a hundred
/// thousand lines, and reading them costs main-isolate time in the middle of
/// PTY ingest. The tail is what is kept: a build puts the thing that broke at
/// the end.
const int kDefaultCommandOutputLines = 200;

/// Why a watched command stopped being watched.
enum CommandRunEnd {
  /// The shell reported it finished — `OSC 133 ; D`, exit code and all.
  finished,

  /// It was still running when the caller's timeout expired.
  timedOut,

  /// The pane's process died while it ran, so no end marker will ever come.
  paneExited,
}

/// One command's output, read straight out of the terminal buffer.
class CommandOutputText {
  const CommandOutputText({
    required this.lines,
    required this.scoped,
    this.omitted = 0,
  });

  /// What we hand back when the command's own region cannot be located.
  static const CommandOutputText unscoped = CommandOutputText(
    lines: <String>[],
    scoped: false,
  );

  final List<String> lines;

  /// Whether [lines] really is *this command's* output.
  ///
  /// False when the command never started, or when its output has already
  /// scrolled out of the pane's history — in which case [lines] is empty rather
  /// than a plausible-looking screenful of somebody else's output.
  final bool scoped;

  /// Lines dropped from the head to honour the cap.
  final int omitted;
}

/// The result of waiting on one command.
class CommandRunOutcome {
  const CommandRunOutcome({
    required this.end,
    required this.output,
    required this.markersSeen,
    this.exitCode,
    this.duration,
  });

  final CommandRunEnd end;
  final CommandOutputText output;

  /// The exit code, or `null` when nobody reported one.
  ///
  /// Two things can report it, and the difference is in [end] rather than
  /// here: the shell's own OSC 133 `D` marker for a command that
  /// [CommandRunEnd.finished], and the **pane** for one whose process died
  /// under it — a host-backed session is told what its session exited with.
  ///
  /// `null` means *unknown*, never *zero*: an interrupted command completes
  /// with no code, and calling that success would be a lie a caller acts on.
  final int? exitCode;

  final Duration? duration;

  /// Whether this pane has ever produced an OSC 133 marker.
  ///
  /// The honest answer to "why did nothing happen": a pane that has never
  /// emitted one is probably not running the integration at all, which is a
  /// different problem from a command that is genuinely slow.
  final bool markersSeen;

  bool get finished => end == CommandRunEnd.finished;
}

/// The text one command printed: the buffer between its `C` and its `D`.
///
/// Both ends matter. The `D` marker anchors to the line the **next prompt** is
/// about to be drawn on, so taking whole lines would hand back that prompt and,
/// a keystroke later, whatever the user typed next. And [CommandBlock.endRef]
/// being absent is not an error — it is a command that is still running, and
/// then the answer is everything printed so far.
CommandOutputText readCommandOutput(
  Terminal terminal,
  CommandBlock block, {
  int maxLines = kDefaultCommandOutputLines,
}) {
  final start = block.outputRef;
  final startLine = start?.line;
  // No `C` means nothing ran; a null line means the output has been evicted
  // from scrollback. Neither can be scoped, and neither may be papered over
  // with whatever happens to be on screen instead.
  if (start == null || startLine == null) return CommandOutputText.unscoped;

  final end = block.endRef;
  final endLine = end?.line;
  final running = end == null || endLine == null;
  // A running command has no end marker, so it is read to the end of the
  // buffer — which is exactly what "what it has printed so far" means.
  var last = running ? terminal.buffer.lines.length - 1 : endLine;
  final endColumn = running ? null : _columnOf(end);
  if (last < startLine) return CommandOutputText.unscoped;

  // Trailing blanks first, then the cap: the empty row the `D` marker sits on
  // must not eat a line of the caller's budget.
  while (last > startLine &&
      _isBlankRow(terminal, last, last == endLine ? endColumn : null)) {
    last--;
  }

  final total = last - startLine + 1;
  final omitted = total > maxLines ? total - maxLines : 0;
  final from = startLine + omitted;

  final lines = <String>[];
  for (var y = from; y <= last; y++) {
    if (y >= terminal.buffer.lines.length) break;
    lines.add(
      _rowText(
        terminal,
        y,
        from: y == startLine ? _columnOf(start) : 0,
        to: y == endLine ? endColumn : null,
      ),
    );
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return CommandOutputText(lines: lines, scoped: true, omitted: omitted);
}

/// The column a marker landed on, or 0 for a [TerminalLineRef] that does not
/// carry one (the pure test doubles; production always anchors to a cell).
int _columnOf(TerminalLineRef ref) => ref is CellAnchorLineRef ? ref.column : 0;

bool _isBlankRow(Terminal terminal, int y, int? to) {
  if (y >= terminal.buffer.lines.length) return true;
  final line = terminal.buffer.lines[y];
  final end = to == null || to > line.length ? line.length : to;
  for (var i = 0; i < end; i++) {
    if (line.getCodePoint(i) > 32) return false;
  }
  return true;
}

/// One row as plain text, styling dropped.
///
/// A cell that was never written reads as 0; it becomes a space, the same way
/// `terminalTailLines` renders it, so `terminal_run` and `terminal_output`
/// never disagree about what a line says.
String _rowText(Terminal terminal, int y, {required int from, int? to}) {
  final line = terminal.buffer.lines[y];
  final end = to == null || to > line.length ? line.length : to;
  final out = StringBuffer();
  for (var i = from; i < end; i++) {
    final code = line.getCodePoint(i);
    out.writeCharCode(code == 0 ? 32 : code);
  }
  return out.toString().trimRight();
}

/// Waits for the *one* command a caller is about to type into a pane.
///
/// A PTY is a byte stream with no notion of "this command finished, here is its
/// status", which is why typing into a pane and polling for a new prompt was
/// all an agent could do. OSC 133 is that notion, and this is the seam that
/// turns it into a single round trip: begin the watch, type, await.
///
/// It only ever **reads** the terminal — the pane owns its own state — and it
/// never polls: the markers arrive on the PTY's own callback, so nothing here
/// occupies a frame while a command runs.
class CommandRunWatch {
  CommandRunWatch._(this._instance, this._recorder, this._maxOutputLines) {
    // Whatever is running *now* is not what the caller is about to type. Its
    // `D` will arrive first and must not be mistaken for ours — the difference
    // between waiting for a command and waiting for a marker.
    final pending = _tracker.pending;
    _skip = pending != null && pending.hasStarted ? pending : null;
    _tracker.addCompletionListener(_onCompleted);
    _instance.liveness.addListener(_onLiveness);
  }

  /// Starts watching [instance], or returns `null` when it has no shell
  /// integration and therefore no way to report an end.
  ///
  /// Call **before** typing: a fast command can finish inside the same turn the
  /// keystroke was written in.
  static CommandRunWatch? begin(
    TerminalInstance instance, {
    int maxOutputLines = kDefaultCommandOutputLines,
  }) {
    final recorder = instance.commandBlocks;
    if (recorder == null) return null;
    return CommandRunWatch._(instance, recorder, maxOutputLines);
  }

  final TerminalInstance _instance;
  final CommandBlockRecorder _recorder;
  final int _maxOutputLines;

  final Completer<CommandBlock?> _settled = Completer<CommandBlock?>();

  /// The command that was already running when the watch began, if any.
  CommandBlock? _skip;

  /// This command's output, captured the moment it ended (see [_onCompleted]).
  CommandOutputText? _captured;

  bool _cancelled = false;

  CommandBlockTracker get _tracker => _recorder.tracker;

  /// Waits up to [timeout] for the command to finish.
  ///
  /// Always answers: a command that never ends returns what it has printed so
  /// far, marked [CommandRunEnd.timedOut], rather than hanging on `vim`.
  Future<CommandRunOutcome> awaitFinish(Duration timeout) async {
    try {
      final block = await _settled.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      if (block != null) {
        return CommandRunOutcome(
          end: CommandRunEnd.finished,
          output: _captured ?? CommandOutputText.unscoped,
          exitCode: block.exitCode,
          duration: block.duration,
          markersSeen: true,
        );
      }
      return _unfinished(
        _instance.liveness.value.isLive
            ? CommandRunEnd.timedOut
            : CommandRunEnd.paneExited,
      );
    } finally {
      cancel();
    }
  }

  /// Stops watching. Safe to call twice, and safe after the pane has gone.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _tracker.removeCompletionListener(_onCompleted);
    _instance.liveness.removeListener(_onLiveness);
  }

  void _onCompleted(CommandBlock block) {
    if (identical(block, _skip)) {
      // The command that was already running has ended. The pane is free now,
      // but this was never our command.
      _skip = null;
      return;
    }
    if (_settled.isCompleted) return;
    // Read the output *here*, inside the `D` marker's own callback, while the
    // buffer still ends at this command's last line: the next prompt is drawn
    // a few bytes later, on the very line the marker anchored to, and the
    // anchors themselves can be moved by any line editing that follows.
    _captured = readCommandOutput(
      _instance.terminal,
      block,
      maxLines: _maxOutputLines,
    );
    _settled.complete(block);
  }

  void _onLiveness() {
    if (_instance.liveness.value.isLive || _settled.isCompleted) return;
    // The shell died — typed `exit`, or the command took it down. No `D` is
    // coming, and waiting out the timeout for one would be theatre.
    _settled.complete(null);
  }

  CommandRunOutcome _unfinished(CommandRunEnd end) {
    final running = _tracker.pending;
    final ours =
        running != null && running.hasStarted && !identical(running, _skip);
    return CommandRunOutcome(
      end: end,
      output: ours
          ? readCommandOutput(
              _instance.terminal,
              running,
              maxLines: _maxOutputLines,
            )
          : CommandOutputText.unscoped,
      // No `D` marker is coming, but the pane itself may know what its process
      // died with — a host-backed session carries the host's own code. Only
      // for [CommandRunEnd.paneExited]: a timed-out command is still running,
      // and its pane has no code to give. Null stays null.
      exitCode: end == CommandRunEnd.paneExited ? _instance.exitCode : null,
      markersSeen: _tracker.latest != null,
    );
  }
}
