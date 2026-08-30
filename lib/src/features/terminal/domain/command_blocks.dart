/// OSC 133 shell integration: the marker vocabulary and the state machine that
/// turns a stream of markers into command blocks.
///
/// Pure Dart on purpose — no Flutter, no xterm, no Riverpod — so the whole
/// protocol is unit-testable without a terminal, a process or a widget tree.
library;

/// The four OSC 133 command boundaries.
///
/// * `A` — the prompt starts
/// * `B` — the user's input starts (not every shell emits this)
/// * `C` — the command's output starts, i.e. the command is now running
/// * `D` — the command finished, optionally carrying its exit code
enum ShellMarker { promptStart, commandStart, outputStart, commandEnd }

/// Reads an OSC dispatched by xterm's `onPrivateOSC` as a command boundary, or
/// `null` when it is not one.
///
/// [code] is the OSC number as a string and [args] everything after it, so
/// `OSC 133 ; D ; 1 ST` arrives as `('133', ['D', '1'])`. Anything that is not
/// OSC 133, and any 133 sub-code we do not model (`E`, `L`, `P`, …), is ignored
/// rather than guessed at.
ShellMarker? shellMarkerFromOsc(String code, List<String> args) {
  if (code != '133' || args.isEmpty) return null;
  return switch (args.first) {
    'A' => ShellMarker.promptStart,
    'B' => ShellMarker.commandStart,
    'C' => ShellMarker.outputStart,
    'D' => ShellMarker.commandEnd,
    _ => null,
  };
}

/// The exit code carried by an `OSC 133 ; D ; <code>`, or `null` when it is
/// absent or unparseable.
///
/// `null` means *unknown*, never *failed* — a shell that reports no code must
/// not have its commands drawn as failures.
int? exitCodeFromOsc(List<String> args) {
  if (args.length < 2) return null;
  return int.tryParse(args[1]);
}

/// A reference to a line in the terminal buffer that survives the buffer moving
/// underneath it, and reports `null` once that line is evicted from scrollback.
///
/// The model depends on this narrow interface rather than on xterm's
/// `CellAnchor` so it stays pure; production supplies an anchor-backed
/// implementation, tests supply a plain holder.
abstract class TerminalLineRef {
  /// The line's current absolute index, or `null` if it no longer exists.
  int? get line;
}

/// One command the shell ran: where it sits in the buffer, what it was, how it
/// ended and how long it took.
class CommandBlock {
  CommandBlock({
    required this.id,
    required this.promptRef,
    required this.promptAt,
    this.startedAt,
    this.inputRef,
    this.outputRef,
    this.endRef,
    this.command,
    this.exitCode,
    this.endedAt,
  });

  /// Stable within one terminal session; used as a widget key and as the
  /// identity for "jump to this command".
  final String id;

  /// The line the prompt was drawn on — the scroll target for navigation.
  final TerminalLineRef promptRef;

  /// Where the user's input began (`B`). Absent for shells that do not emit it.
  TerminalLineRef? inputRef;

  /// Where the command's output began (`C`).
  TerminalLineRef? outputRef;

  /// Where the command finished (`D`).
  TerminalLineRef? endRef;

  /// The command text, when the shell gave us enough to recover it.
  String? command;

  /// The reported exit code, or `null` when the shell reported none.
  int? exitCode;

  /// When the prompt was drawn (the `A` marker).
  final DateTime promptAt;

  /// When the command started running (the `C` marker), or `null` if it never
  /// did. Duration is measured from here, not from [promptAt] — the time the
  /// prompt spent waiting for the user to type is not the command's runtime.
  DateTime? startedAt;

  /// When the command finished (the `D` marker), or `null` while it runs.
  DateTime? endedAt;

  /// The prompt's current line, or `null` once it has scrolled out of history.
  int? get promptLine => promptRef.line;

  bool get isRunning => endedAt == null;

  /// True once the shell said the command is actually running.
  bool get hasStarted => startedAt != null;

  /// True only for a *known* non-zero exit code. An unknown code is not a
  /// failure.
  bool get failed => exitCode != null && exitCode != 0;

  Duration? get duration => (endedAt == null || startedAt == null)
      ? null
      : endedAt!.difference(startedAt!);
}

/// Consumes a stream of [ShellMarker]s and produces completed [CommandBlock]s.
///
/// The rules that are not obvious, each of which is pinned by a test:
///
/// * A block is only real once `C` has been seen. Pressing Enter on an empty
///   line emits `A … D` with no `C`, and that is not a command.
/// * A `D` with nothing pending is dropped, because integration can begin
///   part-way through a session.
/// * A fresh `A` closes a block that had started running (the user interrupted
///   it) with an unknown exit code, and discards one that never started.
class CommandBlockTracker {
  CommandBlockTracker({this.maxBlocks = 200});

  /// How many completed blocks to retain; the oldest are dropped past this.
  /// Bounds memory in a long-lived pane.
  final int maxBlocks;

  final List<CommandBlock> _blocks = [];
  CommandBlock? _pending;
  int _nextId = 0;

  /// Completed commands, oldest first.
  List<CommandBlock> get blocks => List.unmodifiable(_blocks);

  /// The command currently being typed or run, if any.
  CommandBlock? get pending => _pending;

  /// The most recently completed or running block.
  CommandBlock? get latest =>
      _pending ?? (_blocks.isEmpty ? null : _blocks.last);

  void onMarker(
    ShellMarker marker, {
    required TerminalLineRef ref,
    required DateTime at,
    int? exitCode,
    String? command,
  }) {
    switch (marker) {
      case ShellMarker.promptStart:
        // A command that was already running is finished by the next prompt
        // even without a D — an interrupt does that. One that never started is
        // just an abandoned prompt line.
        final previous = _pending;
        if (previous != null && previous.outputRef != null) {
          previous.endedAt = at;
          _complete(previous);
        }
        _pending = CommandBlock(
          id: 'cmd-${_nextId++}',
          promptRef: ref,
          promptAt: at,
        );
      case ShellMarker.commandStart:
        _pending?.inputRef = ref;
      case ShellMarker.outputStart:
        final block = _pending;
        if (block == null) return;
        block
          ..outputRef = ref
          ..startedAt = at
          ..command = command ?? block.command;
      case ShellMarker.commandEnd:
        final block = _pending;
        // No C means nothing ran; drop the block rather than inventing one.
        if (block == null || block.outputRef == null) {
          _pending = null;
          return;
        }
        block
          ..endRef = ref
          ..endedAt = at
          ..exitCode = exitCode;
        _complete(block);
    }
  }

  void _complete(CommandBlock block) {
    _blocks.add(block);
    _pending = null;
    if (_blocks.length > maxBlocks) {
      _blocks.removeRange(0, _blocks.length - maxBlocks);
    }
  }

  /// Drops blocks whose prompt line has been evicted from scrollback, so a
  /// navigation target can never point at a line that no longer exists.
  void pruneEvicted() {
    _blocks.removeWhere((block) => block.promptRef.line == null);
  }

  /// The first command whose prompt sits strictly below [line].
  CommandBlock? nextAfter(int line) {
    for (final block in _blocks) {
      final at = block.promptRef.line;
      if (at != null && at > line) return block;
    }
    return null;
  }

  /// The last command whose prompt sits strictly above [line].
  CommandBlock? previousBefore(int line) {
    for (final block in _blocks.reversed) {
      final at = block.promptRef.line;
      if (at != null && at < line) return block;
    }
    return null;
  }
}
