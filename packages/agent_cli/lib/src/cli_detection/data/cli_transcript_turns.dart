part of 'cli_transcript_reader.dart';

/// Where a [readTranscriptTurns] stopped, in a form that survives a restart:
/// an offset and the bytes that identify the file there, never parse state.
class TranscriptResumePoint {
  TranscriptResumePoint({
    required this.end,
    required this.rows,
    Uint8List? anchor,
    Uint8List? head,
  }) : anchor = anchor ?? Uint8List(0),
       head = head ?? Uint8List(0);

  /// The offset just past the last newline parsed.
  final int end;

  /// Rows, of every role, the parse had produced by [end] — the ordinal the
  /// next row is given.
  final int rows;

  /// The bytes ending at [end], and the file's first bytes. A resume that
  /// finds either changed reads the whole file again.
  final Uint8List anchor;
  final Uint8List head;
}

/// One row a search may index, with its position in the transcript as parsed.
class IndexableTurn {
  const IndexableTurn({
    required this.ordinal,
    required this.role,
    required this.text,
    this.at,
  });

  final int ordinal;
  final String role;
  final String text;
  final DateTime? at;
}

/// What one [readTranscriptTurns] found.
class TranscriptTurnsRead {
  const TranscriptTurnsRead({
    required this.turns,
    required this.appended,
    required this.bytesRead,
    this.resumePoint,
  });

  /// Includes the turns of a last record the writer has not ended with a
  /// newline yet. Those sit past [resumePoint] — their ordinals are at least
  /// its `rows` — so the next read yields them again, and a caller that keeps
  /// turns replaces from there rather than appending twice.
  final List<IndexableTurn> turns;

  /// True when [turns] follow on from the point the read resumed at; false
  /// when they are the whole file, which replaces anything held before.
  final bool appended;

  /// Null when the file could not be read to a record boundary; the next read
  /// then starts over.
  final TranscriptResumePoint? resumePoint;

  /// Transcript bytes this read went through — the cost claim.
  final int bytesRead;

  static const TranscriptTurnsRead nothing = TranscriptTurnsRead(
    turns: [],
    appended: false,
    bytesRead: 0,
  );
}

/// The rows of [messages] whose role is in [roles] and which say something,
/// numbered from [firstOrdinal]. `text` only — a row's `thinking` never is.
List<IndexableTurn> transcriptTurnsOf(
  List<TranscriptMessage> messages,
  Set<String> roles, {
  int firstOrdinal = 0,
}) => [
  for (var i = 0; i < messages.length; i++)
    if (roles.contains(messages[i].role) && messages[i].text.isNotEmpty)
      IndexableTurn(
        ordinal: firstOrdinal + i,
        role: messages[i].role,
        text: messages[i].text,
        at: messages[i].at,
      ),
];

/// The [roles] rows of a transcript, reading only what was appended after
/// [from] when the file still begins with what that read saw.
///
/// The persistent counterpart of [CliTranscriptTail]: the resume point is an
/// offset plus identifying bytes, so it can be stored and survive a restart.
/// That is enough for a search index because a visible turn is complete
/// within its own line; what the parse state carries across lines — pending
/// calls, subagent joins, the background ledger — only ever touches tool
/// rows. A file that shrank or changed before [from] is read whole again.
///
/// Whatever is to be parsed — the whole file, or only its append — runs on
/// the caller up to [onCallerBytes] and on a worker isolate past it, the
/// bound [CliTranscriptTail] uses. Only the matching turns come back across
/// the isolate boundary, never the tool rows.
Future<TranscriptTurnsRead> readTranscriptTurns(
  String filePath,
  String cli, {
  required Set<String> roles,
  TranscriptResumePoint? from,
  int onCallerBytes = kTranscriptTailOnCallerBytes,
}) async {
  final path = transcriptFileFor(filePath, cli);
  if (path == null) return TranscriptTurnsRead.nothing;
  if (from != null) {
    try {
      final length = await File(path).length();
      if (await _isPrefixAt(path, from.head, from.anchor, from.end, length)) {
        final roleSet = Set.of(roles);
        return length - from.end <= onCallerBytes
            ? await _turnsFrom(path, cli, roleSet, from)
            : await Isolate.run(() => _turnsFrom(path, cli, roleSet, from));
      }
    } catch (_) {
      // Gone, locked or rewritten under us: the whole-file read decides.
    }
  }
  // Asked here too, so a gone transcript costs a stat rather than a worker.
  final int length;
  try {
    length = await File(path).length();
  } on FileSystemException {
    return TranscriptTurnsRead.nothing;
  }
  final roleSet = Set.of(roles);
  // A small file parses faster than a worker spawns — and a backfill reads
  // thousands of them — so only a large one pays for the isolate.
  return length <= onCallerBytes
      ? _wholeTurns(path, cli, roleSet)
      : Isolate.run(() => _wholeTurns(path, cli, roleSet));
}

Future<TranscriptTurnsRead> _wholeTurns(
  String path,
  String cli,
  Set<String> roles,
) async {
  if (!await File(path).exists()) return TranscriptTurnsRead.nothing;
  final start = TranscriptResumePoint(end: 0, rows: 0);
  try {
    final read = await _turnsFrom(path, cli, roles, start);
    return TranscriptTurnsRead(
      turns: read.turns,
      appended: false,
      bytesRead: read.bytesRead,
      resumePoint: read.resumePoint,
    );
  } catch (_) {
    // As [readCliTranscript] answers a locked file: nothing, and no point to
    // resume from, so the next read starts over.
    return TranscriptTurnsRead.nothing;
  }
}

/// Parses [path] from [from] with a fresh parse. The unterminated last record
/// is parsed into a copy and not resumed past, as [CliTranscriptTail] does.
Future<TranscriptTurnsRead> _turnsFrom(
  String path,
  String cli,
  Set<String> roles,
  TranscriptResumePoint from,
) async {
  final parse = _TranscriptParse(transcriptDialectFor(cli));
  final read = await readBoundedLinesFrom(
    File(path),
    from.end,
    parse.add,
    before: from.anchor,
  );
  var head = from.head;
  final headLength = read.end < _kTailHeadBytes ? read.end : _kTailHeadBytes;
  if (head.length < headLength) head = await _bytesAt(path, 0, headLength);
  var finished = parse;
  final rest = read.rest;
  if (rest != null && rest.isNotEmpty) finished = parse.copy()..add(rest);
  return TranscriptTurnsRead(
    turns: transcriptTurnsOf(finished.messages, roles, firstOrdinal: from.rows),
    appended: true,
    bytesRead: read.end - from.end,
    resumePoint: TranscriptResumePoint(
      end: read.end,
      rows: from.rows + parse.messages.length,
      anchor: read.anchor,
      head: head,
    ),
  );
}
