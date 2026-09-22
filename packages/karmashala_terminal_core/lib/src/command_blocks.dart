/// OSC 133 shell integration: the marker vocabulary and the state machine that
/// turns a stream of markers into command blocks. Pure Dart on purpose, so the
/// whole protocol is unit-testable without a terminal or a widget tree.
library;

/// The four OSC 133 command boundaries: `A` the prompt starts, `B` the user's
/// input starts (not every shell emits it), `C` the command is now running,
/// `D` it finished, optionally carrying its exit code.
enum ShellMarker { promptStart, commandStart, outputStart, commandEnd }

/// Reads an OSC dispatched by xterm's `onPrivateOSC` as a command boundary, or
/// `null` when it is not one. `OSC 133 ; D ; 1 ST` arrives as
/// `('133', ['D', '1'])`; a sub-code we do not model is ignored, not guessed.
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
/// absent or unparseable. `null` means *unknown*, never *failed* — a shell that
/// reports no code must not have its commands drawn as failures.
int? exitCodeFromOsc(List<String> args) {
  if (args.length < 2) return null;
  return int.tryParse(args[1]);
}

/// A reference to a buffer line that survives the buffer moving, and reports
/// `null` once it is evicted. Narrow, so the model stays free of xterm.
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
    this.resumed = false,
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

  /// When the prompt was drawn (the `A` marker), or null when it was drawn
  /// before this pane could see it — a reattached session's replay. Never the
  /// moment of the reattach, which would be a time nobody measured.
  final DateTime? promptAt;

  /// Whether this command was already running when the pane first saw it: a
  /// session reattached mid-command. Its start time is unknown and stays null,
  /// so it has no duration — and it can never be the command a caller has only
  /// just typed.
  final bool resumed;

  /// When the command started running (the `C` marker), or `null` if it never
  /// did. Duration is measured from here, not from [promptAt] — the time the
  /// prompt spent waiting for the user to type is not the command's runtime.
  DateTime? startedAt;

  /// When the command finished (the `D` marker), or `null` while it runs.
  DateTime? endedAt;

  /// The prompt's current line, or `null` once it has scrolled out of history.
  int? get promptLine => promptRef.line;

  bool get isRunning => endedAt == null;

  /// True once the shell said the command is actually running — including one
  /// that was running before the pane saw it start ([resumed]).
  bool get hasStarted => startedAt != null || outputRef != null;

  /// True only for a *known* non-zero exit code. An unknown code is not a
  /// failure.
  bool get failed => exitCode != null && exitCode != 0;

  Duration? get duration => (endedAt == null || startedAt == null)
      ? null
      : endedAt!.difference(startedAt!);
}

/// Consumes [ShellMarker]s and produces completed [CommandBlock]s. A block is
/// real only once `C` has been seen — an empty Enter emits `A … D` without one.
class CommandBlockTracker {
  CommandBlockTracker({this.maxBlocks = 200});

  /// How many completed blocks to retain; the oldest are dropped past this.
  /// Bounds memory in a long-lived pane.
  final int maxBlocks;

  final List<CommandBlock> _blocks = [];
  final List<void Function(CommandBlock)> _completionListeners = [];
  CommandBlock? _pending;
  int _nextId = 0;

  /// Set by [resume] when the replay carried no marker at all: the shell may be
  /// at a prompt or deep in a command, and nothing says which. Cleared by the
  /// first prompt.
  bool _midStream = false;

  /// Completed commands, oldest first.
  List<CommandBlock> get blocks => List.unmodifiable(_blocks);

  /// The command currently being typed or run, if any.
  CommandBlock? get pending => _pending;

  /// The most recently completed or running block.
  CommandBlock? get latest =>
      _pending ?? (_blocks.isEmpty ? null : _blocks.last);

  /// Called with each block the moment it completes, in completion order —
  /// what lets `terminal_run` wait rather than poll. Listeners **observe**.
  void addCompletionListener(void Function(CommandBlock block) listener) =>
      _completionListeners.add(listener);

  void removeCompletionListener(void Function(CommandBlock block) listener) =>
      _completionListeners.remove(listener);

  void onMarker(
    ShellMarker marker, {
    required TerminalLineRef ref,
    required DateTime at,
    int? exitCode,
    String? command,
  }) {
    switch (marker) {
      case ShellMarker.promptStart:
        _midStream = false;
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
        if (block == null && _midStream) {
          // The end of a command that started before the pane could see it:
          // its exit code is real, its start is not known and is not made up.
          _midStream = false;
          _complete(
            CommandBlock(
              id: 'cmd-${_nextId++}',
              promptRef: ref,
              promptAt: null,
              endRef: ref,
              endedAt: at,
              exitCode: exitCode,
              resumed: true,
            ),
          );
          return;
        }
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

  /// Picks the state back up after a reattach whose replay was read **for state
  /// only**: [last] is the last marker the replay carried, and the refs are
  /// where that replay's latest prompt, input and output began.
  ///
  /// No block is completed here — the replay's finished commands would carry
  /// the reattach's timestamps and a zero duration. What survives is what the
  /// next live marker needs: whether a prompt is up, or a command is running.
  void resume({
    required ShellMarker? last,
    TerminalLineRef? prompt,
    TerminalLineRef? input,
    TerminalLineRef? output,
  }) {
    _pending = null;
    _midStream = false;
    switch (last) {
      case null:
        _midStream = true;
      case ShellMarker.promptStart || ShellMarker.commandStart:
        // At a prompt: the next command is typed live, so its C is a real time.
        final at = prompt ?? input;
        if (at == null) {
          _midStream = true;
          return;
        }
        _pending = CommandBlock(
          id: 'cmd-${_nextId++}',
          promptRef: at,
          promptAt: null,
          inputRef: input,
        );
      case ShellMarker.outputStart:
        final ran = output;
        if (ran == null) {
          _midStream = true;
          return;
        }
        _pending = CommandBlock(
          id: 'cmd-${_nextId++}',
          promptRef: prompt ?? ran,
          promptAt: null,
          inputRef: input,
          outputRef: ran,
          resumed: true,
        );
      case ShellMarker.commandEnd:
        // Between a command's end and the next prompt: nothing is running.
        break;
    }
  }

  void _complete(CommandBlock block) {
    _blocks.add(block);
    _pending = null;
    if (_blocks.length > maxBlocks) {
      _blocks.removeRange(0, _blocks.length - maxBlocks);
    }
    // Over a copy: a satisfied waiter removes itself from inside this call, and
    // mutating the live list mid-iteration would skip the listener after it.
    for (final listener in List.of(_completionListeners)) {
      listener(block);
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
