/// One bound on how large a single JSONL record may be before it is refused.
///
/// `LineSplitter` streams the file but not the record, and `jsonDecode` has no
/// streaming form — so without this the largest *record* set the reader's peak
/// memory.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The most bytes one transcript record may occupy and still be read.
///
/// Eight times the largest of the 27,112 real records here. A record past it is
/// dropped rather than cut: a cut one is not valid JSON, so the parser would
/// discard it anyway — after paying for the string.
const int kMaxTranscriptLineBytes = 8 * 1024 * 1024;

const int _lf = 0x0a;
const int _cr = 0x0d;

/// [file]'s lines, `LineSplitter`-compatible, with any record over [maxBytes]
/// dropped before it is ever built as a string.
///
/// The split is made on **bytes**, which is the whole point: the bound has to
/// hold before a record becomes a `String`, and that is the allocation it
/// exists to prevent. Decoding is still done over the record's bytes as a
/// whole, so a code point straddling two of `openRead`'s chunks is unaffected.
Stream<String> boundedLines(
  File file, {
  int maxBytes = kMaxTranscriptLineBytes,
}) async* {
  final pending = BytesBuilder(copy: false);
  // The record being skipped: its bound was already passed, so nothing more of
  // it is kept and the next newline starts a fresh one.
  var dropping = false;

  String decode(Uint8List bytes) {
    var end = bytes.length;
    if (end > 0 && bytes[end - 1] == _cr) end--;
    return utf8.decode(
      end == bytes.length ? bytes : Uint8List.sublistView(bytes, 0, end),
      allowMalformed: true,
    );
  }

  await for (final chunk in file.openRead()) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    var start = 0;
    while (true) {
      final nl = bytes.indexOf(_lf, start);
      if (nl < 0) break;
      if (dropping) {
        dropping = false;
      } else {
        pending.add(Uint8List.sublistView(bytes, start, nl));
        if (pending.length > maxBytes) {
          pending.clear();
        } else {
          yield decode(pending.takeBytes());
        }
      }
      start = nl + 1;
    }
    if (start < bytes.length && !dropping) {
      pending.add(Uint8List.sublistView(bytes, start));
      if (pending.length > maxBytes) {
        dropping = true;
        pending.clear();
      }
    }
  }
  if (!dropping && pending.length > 0) yield decode(pending.takeBytes());
}

/// How far [readBoundedLinesFrom] got, and what it could not finish.
typedef BoundedLinesRead = ({
  /// The offset just past the last newline read: where the next read resumes.
  int end,

  /// The record after that newline which the writer has not terminated yet,
  /// decoded as [boundedLines] would at end of file. Null when there is none,
  /// or when it is already past the bound and so would be dropped.
  String? rest,

  /// Up to [kBoundedLinesAnchorBytes] bytes ending at [end], so a resume can
  /// check it is still reading the file it stopped in.
  Uint8List anchor,
});

/// How many bytes before a resume point [readBoundedLinesFrom] reports.
const int kBoundedLinesAnchorBytes = 256;

/// [boundedLines]' split of [file] from byte [start], resumable.
///
/// Only newline-terminated records reach [onLine]; the unterminated remainder
/// is returned instead, because a writer may still be adding to it. [before]
/// is the anchor of the read that stopped at [start], when there was one.
Future<BoundedLinesRead> readBoundedLinesFrom(
  File file,
  int start,
  void Function(String line) onLine, {
  Uint8List? before,
  int maxBytes = kMaxTranscriptLineBytes,
}) async {
  final pending = BytesBuilder(copy: false);
  var dropping = false;
  var offset = start;
  var end = start;
  // The last bytes streamed, so the anchor can be cut at the final newline
  // without a second read of the file.
  var recent = before ?? Uint8List(0);
  var anchor = recent;

  Uint8List lastBytes(Uint8List a, Uint8List b) {
    final total = a.length + b.length;
    final keep = total < kBoundedLinesAnchorBytes
        ? total
        : kBoundedLinesAnchorBytes;
    final out = Uint8List(keep);
    final fromB = b.length < keep ? b.length : keep;
    final fromA = keep - fromB;
    out.setRange(0, fromA, a, a.length - fromA);
    out.setRange(fromA, keep, b, b.length - fromB);
    return out;
  }

  await for (final chunk in file.openRead(start)) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    var from = 0;
    var lastNl = -1;
    while (true) {
      final nl = bytes.indexOf(_lf, from);
      if (nl < 0) break;
      lastNl = nl;
      if (dropping) {
        dropping = false;
      } else {
        pending.add(Uint8List.sublistView(bytes, from, nl));
        if (pending.length > maxBytes) {
          pending.clear();
        } else {
          onLine(_decodeRecord(pending.takeBytes()));
        }
      }
      from = nl + 1;
    }
    if (from < bytes.length && !dropping) {
      pending.add(Uint8List.sublistView(bytes, from));
      if (pending.length > maxBytes) {
        dropping = true;
        pending.clear();
      }
    }
    if (lastNl >= 0) {
      end = offset + lastNl + 1;
      anchor = lastBytes(recent, Uint8List.sublistView(bytes, 0, lastNl + 1));
    }
    recent = lastBytes(recent, bytes);
    offset += bytes.length;
  }
  return (
    end: end,
    rest: !dropping && pending.length > 0
        ? _decodeRecord(pending.takeBytes())
        : null,
    anchor: anchor,
  );
}

String _decodeRecord(Uint8List bytes) {
  var end = bytes.length;
  if (end > 0 && bytes[end - 1] == _cr) end--;
  return utf8.decode(
    end == bytes.length ? bytes : Uint8List.sublistView(bytes, 0, end),
    allowMalformed: true,
  );
}
