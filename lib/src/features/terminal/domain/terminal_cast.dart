import 'dart:convert';

/// What one recorded event is.
///
/// Only two kinds are produced. Output is the bytes the process wrote; resize
/// is the grid changing underneath it, which a replay has to reproduce or every
/// later line wraps in the wrong place. asciinema also defines `i` (keystrokes)
/// and `m` (markers); neither is recorded — see [TerminalCast] on why input is
/// deliberately not captured.
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

/// A recording of a terminal pane: the grid it started on, and the bytes that
/// arrived, each stamped with when.
///
/// **Data, not pixels.** A minute of a busy shell is tens of kilobytes, and can
/// be re-rendered afterwards at any size, font and theme — and it can never
/// contain a notification that popped up, another window, or the rest of the
/// desktop, because none of that was ever in the pipe. A screen capture would
/// have thrown all of that away.
///
/// **Output only.** Keystrokes are not recorded, which is a privacy property
/// rather than an omission: what a shell echoes is in the cast because it was on
/// screen, and what it deliberately does not echo — the password `read -s` is
/// waiting for, a `sudo` prompt — never enters the recording at all. The cast is
/// still whatever *was* on screen and is not redactable; see
/// `TerminalRecordingController` for what the user is told.
///
/// The wire format is [asciinema v2](https://docs.asciinema.org/manual/asciicast/v2/):
/// a JSON header line followed by one JSON array per event. Reading and writing
/// the documented format rather than one of ours means an existing cast plays
/// here and a recording made here plays anywhere.
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
  /// considered.
  ///
  /// This is what a renderer has to frame for. A video cannot change size
  /// half-way through, so the frame is cut for the widest and tallest the grid
  /// ever got and a smaller grid simply leaves room unused — the alternative is
  /// re-cropping mid-playback, which reads as a glitch.
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

/// Elapsed time as the format's fractional seconds.
///
/// Microsecond resolution, with trailing zeroes trimmed so a whole second is
/// `1` rather than `1.000000` — asciinema's own writer does the same and the
/// difference is a third of the file's size on a chatty recording.
num formatCastSeconds(Duration at) {
  final micros = at.inMicroseconds;
  if (micros % Duration.microsecondsPerSecond == 0) {
    return micros ~/ Duration.microsecondsPerSecond;
  }
  return double.parse((micros / Duration.microsecondsPerSecond).toStringAsFixed(6));
}

/// Reads back what [encodeCast] wrote.
///
/// Lines that are not events are skipped rather than fatal: a cast recorded
/// elsewhere may carry `i` and `m` events this app does not model, and dropping
/// them plays the recording rather than refusing it.
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
