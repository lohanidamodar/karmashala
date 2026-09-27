import 'dart:async';

import '../../domain/host_session.dart';
import '../../domain/screen_facts.dart';

/// How many lines of one command's output are read back.
const int kCommandOutputLines = 200;

/// Why a watched command stopped being watched.
enum CommandRunEnd {
  /// The shell reported it finished — `OSC 133 ; D`, exit code and all.
  finished,

  /// It was still running when the caller's timeout expired.
  timedOut,

  /// The terminal's process died while it ran, so no end marker will come.
  paneExited,
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
  final ScreenSpan output;

  /// The exit code, or null — *unknown*, never *zero*.
  final int? exitCode;
  final Duration? duration;

  /// Whether this terminal has ever produced an OSC 133 marker.
  final bool markersSeen;

  bool get finished => end == CommandRunEnd.finished;
}

/// Waits for the *one* command a caller is about to type into a terminal the
/// server runs, on the OSC 133 markers its own copy of the screen reads — the
/// app's `CommandRunWatch`, over the server's screen (slice 5b). It only
/// reads, and never polls.
class TerminalCommandRun {
  TerminalCommandRun._(this._session, this._facts, this._now) {
    // A command already running is not the one about to be typed: its `D`
    // arrives first and must not be taken for ours.
    _skipping = _facts.commandRunning;
    _facts.addMarkerListener(_onMarker);
    unawaited(
      _session.ended.then((_) {
        if (!_settled.isCompleted) _settled.complete(null);
      }),
    );
  }

  /// Starts watching [session] — call **before** typing: a fast command
  /// finishes inside the same turn. Null when its screen reads no markers (a
  /// session read back from disk).
  static TerminalCommandRun? begin(
    HostSession session, {
    DateTime Function()? clock,
  }) {
    final facts = session.facts;
    if (facts == null) return null;
    return TerminalCommandRun._(session, facts, clock ?? DateTime.now);
  }

  final HostSession _session;
  final ScreenFacts _facts;
  final DateTime Function() _now;
  final _settled = Completer<ScreenMarker?>();

  bool _skipping = false;
  (int, int)? _start;
  DateTime? _startedAt;
  ScreenSpan? _captured;
  Duration? _duration;
  var _cancelled = false;

  void _onMarker(ScreenMarker marker) {
    if (_settled.isCompleted) return;
    switch (marker.kind) {
      case 'C':
        if (_skipping) return;
        _start = (marker.row, marker.column);
        _startedAt = _now();
      case 'D':
        if (_skipping) {
          _skipping = false;
          return;
        }
        final start = _start;
        // Read here, inside the `D` marker's own turn, while the buffer still
        // ends at this command's last line.
        _captured = start == null
            ? ScreenSpan.unscoped
            : _facts.span(
                start,
                to: (marker.row, marker.column),
                maxLines: kCommandOutputLines,
              );
        final began = _startedAt;
        _duration = began == null ? null : _now().difference(began);
        _settled.complete(marker);
    }
  }

  /// Waits up to [timeout]. Always answers: a command that never ends returns
  /// what it has printed so far, marked [CommandRunEnd.timedOut].
  Future<CommandRunOutcome> awaitFinish(Duration timeout) async {
    try {
      final marker = await _settled.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      if (marker != null) {
        return CommandRunOutcome(
          end: CommandRunEnd.finished,
          output: _captured ?? ScreenSpan.unscoped,
          exitCode: marker.exitCode,
          duration: _duration,
          markersSeen: true,
        );
      }
      final ended = _session.lifecycle.hasEnded;
      final start = _start;
      return CommandRunOutcome(
        end: ended ? CommandRunEnd.paneExited : CommandRunEnd.timedOut,
        output: start == null
            ? ScreenSpan.unscoped
            : _facts.span(start, maxLines: kCommandOutputLines),
        exitCode: ended ? _session.lifecycle.exitCode : null,
        markersSeen: _facts.markersSeen,
      );
    } finally {
      cancel();
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _facts.removeMarkerListener(_onMarker);
  }
}
