part of 'cli_transcript_reader.dart';

/// How a [CliTranscriptTail.read] was served.
enum TranscriptTailRead {
  /// The whole file, on a worker: the first read, or one that could not resume.
  full,

  /// Only what was appended, on the calling isolate.
  delta,

  /// Only what was appended, but enough of it to be parsed on a worker.
  offThreadDelta,
}

/// The most appended bytes [CliTranscriptTail] parses on the calling isolate.
///
/// A delta is parsed at roughly the whole-file rate, so this keeps the caller's
/// share to a few milliseconds; past it the parse state goes to a worker and
/// back, which costs a copy of that state rather than a re-read of the file.
const int kTranscriptTailOnCallerBytes = 256 * 1024;

/// The leading bytes a resume compares, to notice a file replaced wholesale.
const int _kTailHeadBytes = 256;

/// [readCliTranscript] for a file that is read again and again as it grows:
/// each [read] parses only what was appended since the last one, and gives
/// the same answer a whole-file read of the file would.
///
/// A transcript is append-only, compaction included — a Claude Code boundary
/// is a record written after the history it summarises. Anything else, the
/// file shrinking or its bytes before the resume point changing, is read whole
/// again. The parse state lives with the caller rather than on a worker,
/// because a worker would have to send the whole result back on every read.
class CliTranscriptTail {
  CliTranscriptTail(
    this.filePath,
    this.cli, {
    this.subagentsDirectory,
    this.onCallerBytes = kTranscriptTailOnCallerBytes,
  });

  final String filePath;
  final String cli;
  final String? subagentsDirectory;
  final int onCallerBytes;

  _TailState? _state;
  TranscriptTailRead? _lastRead;

  /// How the latest [read] was served; null before the first.
  TranscriptTailRead? get lastRead => _lastRead;

  Future<List<TranscriptMessage>> read() async {
    final path = transcriptFileFor(filePath, cli);
    final state = _state;
    // Not trusted again until a read completes: a failure part-way leaves the
    // state advanced past records whose result was never returned.
    _state = null;
    if (path == null) return const [];
    if (state != null) {
      try {
        final length = await File(path).length();
        if (await _stillPrefixOf(path, state, length)) {
          final onCaller = length - state.end <= onCallerBytes;
          final step = onCaller
              ? await _advance(state, path, filePath, subagentsDirectory)
              : await _advanceOffThread(
                  state,
                  path,
                  filePath,
                  subagentsDirectory,
                );
          _state = step.state;
          _lastRead = onCaller
              ? TranscriptTailRead.delta
              : TranscriptTailRead.offThreadDelta;
          return step.messages;
        }
      } catch (_) {
        // Gone, locked or rewritten under us: the whole-file read decides.
      }
    }
    final step = await _parseWholeOffThread(
      path,
      filePath,
      cli,
      subagentsDirectory,
    );
    _state = step.state;
    _lastRead = TranscriptTailRead.full;
    return step.messages;
  }
}

/// A parse stopped at a record boundary, and what identifies the file there.
class _TailState {
  _TailState(this.parse, {this.end = 0, Uint8List? anchor, Uint8List? head})
    : anchor = anchor ?? Uint8List(0),
      head = head ?? Uint8List(0);

  final _TranscriptParse parse;

  /// The offset just past the last newline parsed.
  final int end;

  /// The bytes ending at [end], and the file's first bytes.
  final Uint8List anchor;
  final Uint8List head;
}

typedef _TailStep = ({_TailState? state, List<TranscriptMessage> messages});

// Top-level so each closure captures its arguments and nothing else.
Future<_TailStep> _advanceOffThread(
  _TailState state,
  String path,
  String filePath,
  String? subagentsDirectory,
) => Isolate.run(() => _advance(state, path, filePath, subagentsDirectory));

Future<_TailStep> _parseWholeOffThread(
  String path,
  String filePath,
  String cli,
  String? subagentsDirectory,
) => Isolate.run(() => _parseWhole(path, filePath, cli, subagentsDirectory));

Future<_TailStep> _parseWhole(
  String path,
  String filePath,
  String cli,
  String? subagentsDirectory,
) async {
  if (!await File(path).exists()) {
    return (state: null, messages: const <TranscriptMessage>[]);
  }
  final state = _TailState(_TranscriptParse(cli));
  try {
    return await _advance(state, path, filePath, subagentsDirectory);
  } catch (_) {
    // As [readCliTranscript] answers a truncated or locked file: whatever
    // parsed. Not resumable, so the next read starts over.
    final out = state.parse.messages;
    await _finish(out, state.parse, filePath, subagentsDirectory);
    return (state: null, messages: out);
  }
}

/// Parses [path] from where [state] stopped, advancing [state]'s parse.
Future<_TailStep> _advance(
  _TailState state,
  String path,
  String filePath,
  String? subagentsDirectory,
) async {
  final parse = state.parse;
  final read = await readBoundedLinesFrom(
    File(path),
    state.end,
    parse.add,
    before: state.anchor,
  );
  var head = state.head;
  final headLength = read.end < _kTailHeadBytes ? read.end : _kTailHeadBytes;
  if (head.length < headLength) head = await _bytesAt(path, 0, headLength);

  // A last line with no newline yet is parsed into a copy: the writer may
  // still be adding to it, so it is read again next time rather than kept.
  var finished = parse;
  final rest = read.rest;
  if (rest != null && rest.isNotEmpty) finished = parse.copy()..add(rest);
  final out = List.of(finished.messages);
  await _finish(out, finished, filePath, subagentsDirectory);
  return (
    state: _TailState(parse, end: read.end, anchor: read.anchor, head: head),
    messages: out,
  );
}

/// Whether [path] still begins with what [state] parsed.
Future<bool> _stillPrefixOf(String path, _TailState state, int length) =>
    _isPrefixAt(path, state.head, state.anchor, state.end, length);

/// Whether [path], [length] bytes long, still begins with [head] and still
/// holds [anchor] ending at [end].
Future<bool> _isPrefixAt(
  String path,
  Uint8List head,
  Uint8List anchor,
  int end,
  int length,
) async {
  if (length < end) return false;
  final file = await File(path).open();
  try {
    if (!_sameBytes(await file.read(head.length), head)) return false;
    await file.setPosition(end - anchor.length);
    return _sameBytes(await file.read(anchor.length), anchor);
  } finally {
    await file.close();
  }
}

Future<Uint8List> _bytesAt(String path, int offset, int length) async {
  final file = await File(path).open();
  try {
    await file.setPosition(offset);
    return await file.read(length);
  } finally {
    await file.close();
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
