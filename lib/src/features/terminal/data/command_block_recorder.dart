import 'package:xterm2/xterm.dart';

import '../domain/command_blocks.dart';
import '../domain/osc_router.dart';

/// The most lines of typed input we will read back as one command.
///
/// A pasted script can put hundreds of lines between `B` and `C`; the command
/// label only needs the first line or two, and reading the whole paste on every
/// command would be a per-command cost proportional to what the user pasted.
const kMaxCommandTextLines = 4;

/// A [TerminalLineRef] backed by one of xterm's own [CellAnchor]s.
///
/// The anchor rides along with buffer mutations and detaches itself when its
/// line is evicted from scrollback, which is exactly the contract
/// [TerminalLineRef] describes — and it is existing public API, so tracking
/// command positions costs no divergence in the vendored package.
class CellAnchorLineRef implements TerminalLineRef {
  CellAnchorLineRef(this.anchor);

  final CellAnchor anchor;

  /// The column the marker arrived at, captured up front because [CellAnchor.x]
  /// keeps moving as the line is edited.
  late final int column = anchor.x;

  @override
  int? get line => anchor.attached ? anchor.y : null;
}

/// Bridges xterm's `onPrivateOSC` callback to the pure [CommandBlockTracker].
///
/// This is the only place the two meet: everything about the OSC 133 protocol
/// lives in the pure model, and everything about the terminal buffer lives
/// here.
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

  /// Starts listening. Call before the process starts, so no marker is missed.
  ///
  /// Through the pane's [OscRouter] rather than by taking
  /// `terminal.onPrivateOSC`: that slot is single-occupancy and the OSC 7
  /// working directory needs the same stream, whether or not a recorder exists.
  void attach(OscRouter router) => router.add(handleOsc);

  /// Handles one OSC dispatched by xterm. Anything that is not an OSC 133
  /// command boundary is ignored.
  void handleOsc(String code, List<String> args) {
    final marker = shellMarkerFromOsc(code, args);
    if (marker == null) return;

    final ref = CellAnchorLineRef(terminal.buffer.createAnchorFromCursor());
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

  /// The text the user typed: everything between the `B` marker and [end].
  ///
  /// Returns null when the shell emitted no `B` (bash does not), or when either
  /// end has already scrolled out of history.
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
