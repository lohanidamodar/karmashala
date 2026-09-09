/// One bound on transcript text, for every path a message travels.
///
/// A tool that prints a megabyte is ordinary; carrying it is not. What is *not*
/// ordinary is three paths disagreeing about how much of it to keep — and this
/// app had exactly that: the live stream to the phone bounded nothing, the rows
/// a session stores bounded nothing, and the rehydration that re-reads an
/// agent's own store cut at 20,000 UTF-16 code units. A phone that reopened a
/// session was therefore handed a payload the live path would have trimmed, and
/// the transcript changed depending on which door it came through.
///
/// So the bound belongs to the **text**, not to a path, and there is one
/// function and one number. 64 KiB is far more text than a reader reads and far
/// less than a build log, which is the split it is drawn on.
///
/// In `core/util` for the reason `text_links.dart` states about its own
/// primitives: the alternative is a second cut, and two cuts are two answers to
/// "how much of this do we keep" that drift apart. `core` cannot import
/// `features`, which is what keeps it the only answer.
library;

import 'dart:convert';

/// The most bytes of one transcript message this app will move — anywhere.
const int kMaxTranscriptTextBytes = 64 * 1024;

/// [text] cut to [maxBytes] of UTF-8, and whether cutting was needed.
///
/// **Bytes, and never a broken one.** The obvious `substring` counts UTF-16
/// code units, which is neither what a wire budget is spent in nor safe to cut
/// on: an index chosen by length can fall between the halves of a surrogate
/// pair and leave a lone surrogate that no UTF-8 encoder can represent. So the
/// cut is made on the encoded bytes and then walked back to a code-point
/// boundary — the same discipline `scrcpy` applies to the strings it truncates.
///
/// Returns the receiver itself when nothing needs taking, so the overwhelming
/// majority of messages cost one length check and no copy.
(String, bool) boundedText(String text, {int maxBytes = kMaxTranscriptTextBytes}) {
  // Cheap reject first: one UTF-8 byte per code unit is the floor, so any
  // string this short is under the bound whatever it contains.
  if (text.length <= maxBytes ~/ 4) return (text, false);
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return (text, false);
  var end = maxBytes;
  // A continuation byte is 10xxxxxx; walk back off any that start a code point
  // we cannot finish. At most three steps — UTF-8 sequences are four bytes.
  while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
    end--;
  }
  return (utf8.decode(bytes.sublist(0, end), allowMalformed: true), true);
}
