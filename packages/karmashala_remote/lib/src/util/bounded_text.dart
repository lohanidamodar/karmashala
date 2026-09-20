// Copied verbatim from packages/karmashala_core/lib/src/util/bounded_text.dart; see PACKAGE_SPLIT.md on consolidation.
/// One bound on transcript text, for every path a message travels. The bound
/// belongs to the **text**, not to a path: a second cut somewhere else is a
/// second answer to "how much do we keep", and the transcript then changes
/// depending on which door it came through.
library;

import 'dart:convert';

/// The most bytes of one transcript message this app will move — anywhere.
const int kMaxTranscriptTextBytes = 64 * 1024;

/// [text] cut to [maxBytes] of UTF-8, and whether cutting was needed. Cut on
/// encoded bytes and walked back to a code-point boundary: `substring` counts
/// UTF-16 units and can split a surrogate pair into a lone half no UTF-8
/// encoder can represent. Returns the receiver itself when nothing is taken.
(String, bool) boundedText(
  String text, {
  int maxBytes = kMaxTranscriptTextBytes,
}) {
  // One UTF-8 byte per code unit is the floor, so a string this short is under
  // the bound whatever it contains.
  if (text.length <= maxBytes ~/ 4) return (text, false);
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return (text, false);
  var end = maxBytes;
  // A continuation byte is 10xxxxxx: walk back off a code point we cannot
  // finish, at most three steps.
  while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
    end--;
  }
  return (utf8.decode(bytes.sublist(0, end), allowMalformed: true), true);
}
