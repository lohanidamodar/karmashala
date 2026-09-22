import 'package:xterm2/xterm.dart';

import 'package:karmashala_terminal_core/shell_integration.dart';

/// The most lines of typed input read back as one command: a pasted script can
/// put hundreds between `B` and `C`, and the label needs the first one or two.
const kMaxCommandTextLines = 4;

/// A [TerminalLineRef] backed by xterm's own [CellAnchor], which detaches when
/// its line is evicted — public API, so tracking costs no divergence.
class CellAnchorLineRef implements TerminalLineRef {
  CellAnchorLineRef(this.anchor);

  final CellAnchor anchor;

  /// The column the marker arrived at, captured up front because [CellAnchor.x]
  /// keeps moving as the line is edited.
  late final int column = anchor.x;

  @override
  int? get line => anchor.attached ? anchor.y : null;
}

/// Bridges xterm's `onPrivateOSC` callback to the pure [CommandBlockTracker] —
/// the only place the two meet: everything about the protocol lives in the pure
/// model, everything about the terminal buffer lives here.
class CommandBlockRecorder {
  CommandBlockRecorder(
    this.terminal, {
    DateTime Function()? clock,
    int maxBlocks = 200,
  }) : _clock = clock ?? DateTime.now,
       tracker = CommandBlockTracker(maxBlocks: maxBlocks);

  final Terminal terminal;
  final CommandBlockTracker tracker;
  final DateTime Function() _clock;

  /// Where the user's input started, kept so the command text can be read back
  /// when the shell says the command is running.
  CellAnchorLineRef? _inputRef;

  /// Starts listening. Call before the process starts, so no marker is missed;
  /// through the pane's [OscRouter], since that slot is single-occupancy.
  void attach(OscRouter router) => router.add(handleOsc);

  /// Written into the pane's own ingest where a reattach's replay ends, so the
  /// boundary reaches this recorder in order with the bytes around it however
  /// the ingest batches, parks or delays them. Never sent to the process; an
  /// OSC 133 sub-code no shell emits, which every other reader ignores.
  static const String replayEndSequence = '\x1b]133;karmashala-replay-end\x07';
  static const String _replayEndArgument = 'karmashala-replay-end';

  bool _replaying = false;
  ShellMarker? _replayLast;
  CellAnchorLineRef? _replayPrompt;
  CellAnchorLineRef? _replayInput;
  CellAnchorLineRef? _replayOutput;

  /// Whether markers are being read for state only — see [beginReplay].
  bool get isReplaying => _replaying;

  /// Starts reading a reattached session's replay **for state, not blocks**.
  ///
  /// The replay is output the session produced while no pane watched it, so
  /// every block made from it would be stamped with the reattach's time and a
  /// zero duration, and one begun before the replay window would lose its
  /// start. So its markers only decide where the shell is when the replay ends
  /// — at a prompt, or running a command — and [endReplay] hands that on.
  void beginReplay() {
    _replaying = true;
    _replayLast = null;
    _replayPrompt = _replayInput = _replayOutput = null;
  }

  /// Ends the replay and resumes live tracking from the state it left.
  void endReplay() {
    if (!_replaying) return;
    _replaying = false;
    tracker.resume(
      last: _replayLast,
      prompt: _replayPrompt,
      input: _replayInput,
      output: _replayOutput,
    );
    // The command about to be typed is read back from here when its C comes.
    _inputRef = _replayLast == ShellMarker.commandStart ? _replayInput : null;
    _replayPrompt = _replayInput = _replayOutput = null;
  }

  /// Handles one OSC dispatched by xterm. Anything that is not an OSC 133
  /// command boundary is ignored.
  void handleOsc(String code, List<String> args) {
    if (code == '133' && args.isNotEmpty && args.first == _replayEndArgument) {
      endReplay();
      return;
    }
    final marker = shellMarkerFromOsc(code, args);
    if (marker == null) return;

    final ref = CellAnchorLineRef(terminal.buffer.createAnchorFromCursor());
    if (_replaying) {
      _noteReplayed(marker, ref);
      return;
    }
    if (marker == ShellMarker.commandStart) _inputRef = ref;

    tracker.onMarker(
      marker,
      ref: ref,
      at: _clock(),
      exitCode: marker == ShellMarker.commandEnd ? exitCodeFromOsc(args) : null,
      command: marker == ShellMarker.outputStart ? _commandTextTo(ref) : null,
    );

    if (marker == ShellMarker.commandEnd || marker == ShellMarker.promptStart) {
      _inputRef = null;
    }
  }

  void _noteReplayed(ShellMarker marker, CellAnchorLineRef ref) {
    _replayLast = marker;
    switch (marker) {
      case ShellMarker.promptStart:
        _replayPrompt = ref;
        _replayInput = _replayOutput = null;
      case ShellMarker.commandStart:
        _replayInput = ref;
      case ShellMarker.outputStart:
        _replayOutput = ref;
      case ShellMarker.commandEnd:
        _replayPrompt = _replayInput = _replayOutput = null;
    }
  }

  /// The text the user typed: everything between the `B` marker and [end].
  /// Null when the shell emitted no `B` (bash does not), or when either end has
  /// already scrolled out of history.
  String? _commandTextTo(CellAnchorLineRef end) {
    final start = _inputRef;
    if (start == null) return null;
    final startLine = start.line;
    final endLine = end.line;
    if (startLine == null || endLine == null || endLine < startLine) {
      return null;
    }

    final buffer = StringBuffer();
    final lastLine = (startLine + kMaxCommandTextLines - 1) < endLine
        ? startLine + kMaxCommandTextLines - 1
        : endLine;
    for (var y = startLine; y <= lastLine; y++) {
      if (y >= terminal.buffer.lines.length) break;
      final line = terminal.buffer.lines[y];
      final from = y == startLine ? start.column : 0;
      final to = y == endLine ? end.column : line.length;
      if (to > from) buffer.write(line.getText(from, to));
      if (y != lastLine) buffer.write('\n');
    }

    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  }
}
