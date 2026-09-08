import 'dart:convert';
import 'dart:typed_data';

import '../domain/terminal_cast.dart';

/// Most a single recording may hold in memory.
///
/// A pane left recording through a `yes` or a verbose build is otherwise
/// unbounded, and this feature's whole premise is that a recording is
/// kilobytes. 8 MB is minutes of a chatty shell and still a fraction of one
/// second of video; past it the recorder stops adding events and says so, which
/// makes the recording short rather than wrong.
const int kCastMaxBytes = 8 * 1024 * 1024;

/// Turns a pane's output into a [TerminalCast] while it happens.
///
/// Deliberately not a widget, not a provider and not attached to a screen: this
/// holds the recording, so the recording survives the pane being scrolled off,
/// switched away from, or dropped to the cold ingest tier. The tap is on the
/// bytes arriving from the process, which is the one place upstream of all of
/// that.
class CastRecorder {
  CastRecorder({
    required this.columns,
    required this.rows,
    this.title,
    this.maxBytes = kCastMaxBytes,
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

  final Duration Function() _clock;
  final List<CastEvent> _events = [];

  /// Decoded text is accumulated here by [_sink], which holds back a multi-byte
  /// sequence split across two reads instead of turning it into two replacement
  /// characters. flutter_pty reads 1 KB at a time, so that split is ordinary
  /// rather than theoretical.
  final StringBuffer _decoded = StringBuffer();
  late final ByteConversionSink _sink = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(StringConversionSink.fromStringSink(_decoded));

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

  /// Records the grid changing to [columns]x[rows].
  ///
  /// The bytes a reflow produces arrive through [addOutput] like any other
  /// output, so this event is only the geometry: without it a replay keeps
  /// wrapping at the old width and every line after the resize lands wrong.
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

  /// Ends the recording and returns it. Later calls to [addOutput] and
  /// [addResize] do nothing, so a byte still in flight when the user hits stop
  /// cannot extend a recording that has already been handed over.
  TerminalCast stop() {
    _stopped = true;
    return snapshot();
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
