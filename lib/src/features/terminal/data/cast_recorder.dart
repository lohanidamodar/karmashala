import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_terminal_core/cast.dart';

/// Most a single recording may hold in memory. Past it the recorder stops
/// adding events and says so, which makes the recording short, not wrong.
const int kCastMaxBytes = 8 * 1024 * 1024;

/// Turns a pane's output into a [TerminalCast] while it happens. Not a widget:
/// the recording survives the pane going cold or being switched away from.
class CastRecorder {
  CastRecorder({
    required this.columns,
    required this.rows,
    this.title,
    this.maxBytes = kCastMaxBytes,
    this.onSourceEnded,
    DateTime? startedAt,
    Duration Function()? clock,
  }) : recordedAt = startedAt ?? DateTime.now(),
       _clock = clock ?? _stopwatchClock() {
    _lastColumns = columns;
    _lastRows = rows;
  }

  /// A `Stopwatch` started now, as a clock. The default, and the reason tests
  /// can pass their own: a recording is *about* time, so the one thing that must
  /// not be a real clock is the one in a test.
  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// The grid recording started on.
  final int columns;
  final int rows;
  final String? title;
  final int maxBytes;
  final DateTime recordedAt;

  /// Called once when the pane being recorded goes away, so a recording is
  /// never left running against nothing — without it, closing a tab mid-recording
  /// left the button saying "Stop recording" over a pane that no longer exists.
  final void Function()? onSourceEnded;

  final Duration Function() _clock;
  final List<CastEvent> _events = [];

  /// Decoded text is accumulated here by [_sink], which holds back a multi-byte
  /// sequence split across two reads. flutter_pty reads 1 KB at a time, so that
  /// split is ordinary rather than theoretical.
  final StringBuffer _decoded = StringBuffer();
  late final ByteConversionSink _sink = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(StringConversionSink.fromStringSink(_decoded));

  int _bytes = 0;
  int _lastColumns = 0;
  int _lastRows = 0;
  bool _truncated = false;
  bool _stopped = false;

  /// How far into the recording we are.
  Duration get elapsed => _clock();

  /// Events recorded so far.
  int get eventCount => _events.length;

  /// Roughly how much has been kept, in bytes of recorded text.
  int get recordedBytes => _bytes;

  /// Whether the byte cap has been reached and events are being dropped.
  bool get isTruncated => _truncated;

  /// Whether [stop] has been called.
  bool get isStopped => _stopped;

  /// Records output bytes exactly as the process produced them.
  void addOutput(Uint8List bytes) {
    if (_stopped || _truncated || bytes.isEmpty) return;
    _sink.add(bytes);
    if (_decoded.isEmpty) return;
    final text = _decoded.toString();
    _decoded.clear();
    _add(CastEvent.output(_clock(), text), text.length);
  }

  /// Records text the app itself put on screen — the `[process exited with
  /// code 1]` line, an SSH connection banner. In the cast because it was on the
  /// screen; it arrives as text because that is how the pane emits it.
  void addText(String text) {
    if (_stopped || _truncated || text.isEmpty) return;
    _add(CastEvent.output(_clock(), text), text.length);
  }

  /// Records the grid changing to [columns]x[rows]. The bytes a reflow produces
  /// arrive through [addOutput] like any other output, so this event is only
  /// the geometry — without it a replay keeps wrapping at the old width.
  void addResize(int columns, int rows) {
    if (_stopped || _truncated) return;
    if (columns <= 0 || rows <= 0) return;
    if (columns == _lastColumns && rows == _lastRows) return;
    _lastColumns = columns;
    _lastRows = rows;
    final event = CastEvent.resize(_clock(), columns, rows);
    _add(event, event.data.length);
  }

  void _add(CastEvent event, int cost) {
    if (_bytes + cost > maxBytes) {
      _truncated = true;
      return;
    }
    _bytes += cost;
    _events.add(event);
  }

  /// Ends the recording and returns it. Later [addOutput] and [addResize] calls
  /// do nothing, so a byte still in flight when the user hits stop cannot extend
  /// a recording that has already been handed over.
  TerminalCast stop() {
    _stopped = true;
    return snapshot();
  }

  /// The pane this was taping has gone. Stops, then tells whoever is holding
  /// the recording so they can save what there is.
  void sourceEnded() {
    if (_stopped) return;
    _stopped = true;
    onSourceEnded?.call();
  }

  /// The recording as it stands, without ending it.
  TerminalCast snapshot() => TerminalCast(
    columns: columns,
    rows: rows,
    recordedAt: recordedAt,
    title: title,
    truncated: _truncated,
    events: List.unmodifiable(_events),
  );
}
