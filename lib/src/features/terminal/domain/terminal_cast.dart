import 'dart:convert';

/// What one recorded event is: output, or a resize a replay has to reproduce or
/// every later line wraps wrong. asciinema's `i` and `m` are not recorded.
enum CastEventKind {
  output('o'),
  resize('r');

  const CastEventKind(this.code);

  /// The one-letter code the cast file carries.
  final String code;

  static CastEventKind? fromCode(String code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// One `(elapsed, bytes)` chunk — the whole substance of a terminal recording.
class CastEvent {
  const CastEvent(this.at, this.kind, this.data);

  /// Output arriving [at] into the recording.
  const CastEvent.output(this.at, this.data) : kind = CastEventKind.output;

  /// The grid becoming [columns]x[rows] [at] into the recording.
  CastEvent.resize(this.at, int columns, int rows)
    : kind = CastEventKind.resize,
      data = '${columns}x$rows';

  /// Time since the recording started.
  final Duration at;
  final CastEventKind kind;

  /// Text for [CastEventKind.output]; `COLUMNSxROWS` for a resize.
  final String data;

  /// The grid this resize event names, or null if it is not a resize (or names
  /// something unparseable — a hand-edited cast).
  ({int columns, int rows})? get grid {
    if (kind != CastEventKind.resize) return null;
    return parseCastGrid(data);
  }
}

/// `COLUMNSxROWS`, or null when [text] is not that.
({int columns, int rows})? parseCastGrid(String text) {
  final parts = text.split('x');
  if (parts.length != 2) return null;
  final columns = int.tryParse(parts[0]);
  final rows = int.tryParse(parts[1]);
  if (columns == null || rows == null) return null;
  if (columns <= 0 || rows <= 0) return null;
  return (columns: columns, rows: rows);
}

/// A recording of a terminal pane: the bytes that arrived, each stamped with
/// when. **Output only** — a `read -s` password never echoes, so it is never in
/// it.
class TerminalCast {
  const TerminalCast({
    required this.columns,
    required this.rows,
    required this.recordedAt,
    required this.events,
    this.title,
    this.truncated = false,
  });

  /// The grid at the moment recording started. A later [CastEventKind.resize]
  /// changes it.
  final int columns;
  final int rows;

  /// Wall-clock start, so a saved file can say when it was taken.
  final DateTime recordedAt;

  /// What the pane was called.
  final String? title;

  final List<CastEvent> events;

  /// Whether recording stopped adding events because it hit its byte cap. The
  /// events present are still exactly what happened up to that point — a
  /// truncated cast is short, never wrong.
  final bool truncated;

  /// How long the recording runs. The last event's stamp: nothing happens after
  /// it, so nothing is worth rendering after it either.
  Duration get duration => events.isEmpty ? Duration.zero : events.last.at;

  /// The largest grid the recording ever had, header and every resize
  /// considered — what a renderer has to frame for, since a video cannot change
  /// size half-way through and re-cropping mid-playback reads as a glitch.
  ({int columns, int rows}) get widestGrid {
    var maxColumns = columns;
    var maxRows = rows;
    for (final event in events) {
      final grid = event.grid;
      if (grid == null) continue;
      if (grid.columns > maxColumns) maxColumns = grid.columns;
      if (grid.rows > maxRows) maxRows = grid.rows;
    }
    return (columns: maxColumns, rows: maxRows);
  }
}

/// [cast] as an asciinema v2 file.
String encodeCast(TerminalCast cast) {
  final out = StringBuffer();
  out.writeln(
    jsonEncode({
      'version': 2,
      'width': cast.columns,
      'height': cast.rows,
      'timestamp': cast.recordedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      if (cast.title != null) 'title': cast.title,
    }),
  );
  for (final event in cast.events) {
    out.writeln(
      jsonEncode([formatCastSeconds(event.at), event.kind.code, event.data]),
    );
  }
  return out.toString();
}

/// Elapsed time as the format's fractional seconds. Microsecond resolution with
/// trailing zeroes trimmed, as asciinema's own writer does — the difference is
/// a third of the file's size on a chatty recording.
num formatCastSeconds(Duration at) {
  final micros = at.inMicroseconds;
  if (micros % Duration.microsecondsPerSecond == 0) {
    return micros ~/ Duration.microsecondsPerSecond;
  }
  return double.parse((micros / Duration.microsecondsPerSecond).toStringAsFixed(6));
}

/// Reads back what [encodeCast] wrote. Lines that are not events are skipped
/// rather than fatal: a cast recorded elsewhere may carry `i` and `m` events
/// this app does not model, and dropping them plays it rather than refusing.
TerminalCast decodeCast(String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty) throw const FormatException('empty cast');
  final header = jsonDecode(lines.first);
  if (header is! Map<String, Object?>) {
    throw const FormatException('cast header is not an object');
  }
  final version = header['version'];
  if (version != 2) {
    throw FormatException('unsupported asciicast version: $version');
  }
  final columns = header['width'];
  final rows = header['height'];
  if (columns is! int || rows is! int) {
    throw const FormatException('cast header has no grid');
  }
  final timestamp = header['timestamp'];
  final title = header['title'];
  final events = <CastEvent>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final decoded = jsonDecode(line);
    if (decoded is! List || decoded.length < 3) continue;
    final at = decoded[0];
    final kind = CastEventKind.fromCode('${decoded[1]}');
    final data = decoded[2];
    if (at is! num || kind == null || data is! String) continue;
    events.add(
      CastEvent(
        Duration(microseconds: (at * Duration.microsecondsPerSecond).round()),
        kind,
        data,
      ),
    );
  }
  return TerminalCast(
    columns: columns,
    rows: rows,
    recordedAt: timestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(
            (timestamp * 1000).round(),
            isUtc: true,
          )
        : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    title: title is String ? title : null,
    events: events,
  );
}
