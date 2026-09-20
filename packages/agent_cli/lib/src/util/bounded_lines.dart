/// One bound on how large a single JSONL record may be before it is refused.
///
/// `LineSplitter` streams the file but not the record, and `jsonDecode` has no
/// streaming form — so without this the largest *record* set the reader's peak
/// memory. `docs/SETTLED.md`, *Four transcript-tailing traps*, has what was
/// measured and why the number is where it is.
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
