import 'dart:collection';
import 'dart:typed_data';

import 'package:re_editor/re_editor.dart';

/// What one search of a buffer asks for. Plain fields, so it crosses to an
/// isolate as it is.
class CodeSearchRequest {
  const CodeSearchRequest({
    required this.text,
    required this.query,
    this.caseSensitive = false,
    this.regex = false,
    this.wholeWord = false,
    this.maxMatches = kCodeSearchMaxMatches,
  });

  /// The buffer, lines joined with `\n`.
  final String text;
  final String query;
  final bool caseSensitive;
  final bool regex;
  final bool wholeWord;
  final int maxMatches;
}

/// Past this many matches a search stops counting: the count reads as a floor
/// and nothing is highlighted that no one could step through anyway.
const int kCodeSearchMaxMatches = 100000;

/// The pattern [query] searches with, or null for an empty query. Throws the
/// compiler's [FormatException] for a pattern that is not a regex.
RegExp? codeSearchPattern(
  String query, {
  bool caseSensitive = false,
  bool regex = false,
  bool wholeWord = false,
}) {
  if (query.isEmpty) return null;
  var source = regex ? query : RegExp.escape(query);
  if (wholeWord) source = '\\b(?:$source)\\b';
  return RegExp(source, caseSensitive: caseSensitive, multiLine: true);
}

/// Why [query] is not a usable pattern, or null when it is.
String? codeSearchPatternError(
  String query, {
  bool caseSensitive = false,
  bool regex = false,
  bool wholeWord = false,
}) {
  try {
    codeSearchPattern(
      query,
      caseSensitive: caseSensitive,
      regex: regex,
      wholeWord: wholeWord,
    );
    return null;
  } on FormatException catch (error) {
    return error.message;
  }
}

/// Every non-empty match of [request], flattened as
/// `[startLine, startOffset, endLine, endOffset, …]`.
///
/// One pass over the matches and the line breaks together, so the cost is the
/// buffer's length rather than matches times lines. Top level, so `compute`
/// can run it off the UI isolate.
Int32List findCodeMatches(CodeSearchRequest request) {
  final RegExp? pattern;
  try {
    pattern = codeSearchPattern(
      request.query,
      caseSensitive: request.caseSensitive,
      regex: request.regex,
      wholeWord: request.wholeWord,
    );
  } on FormatException {
    return Int32List(0);
  }
  if (pattern == null) return Int32List(0);
  final text = request.text;
  final out = <int>[];
  var line = 0;
  var lineStart = 0;
  var nextBreak = text.indexOf('\n');
  // Moves the running line to the one holding [offset]; offsets only grow, and
  // the next break is remembered, so a long line is not rescanned per match.
  void seek(int offset) {
    while (nextBreak != -1 && nextBreak < offset) {
      line++;
      lineStart = nextBreak + 1;
      nextBreak = text.indexOf('\n', lineStart);
    }
  }

  for (final match in pattern.allMatches(text)) {
    if (match.end == match.start) continue;
    seek(match.start);
    out
      ..add(line)
      ..add(match.start - lineStart);
    seek(match.end);
    out
      ..add(line)
      ..add(match.end - lineStart);
    if (out.length >= request.maxMatches * 4) break;
  }
  return Int32List.fromList(out);
}

/// [findCodeMatches]' flat list, read as selections without building them all.
class CodeMatchList extends ListBase<CodeLineSelection> {
  CodeMatchList(this.flat);

  final Int32List flat;

  @override
  int get length => flat.length ~/ 4;

  @override
  set length(int value) => throw UnsupportedError('read-only');

  @override
  CodeLineSelection operator [](int index) {
    final i = index * 4;
    return CodeLineSelection(
      baseIndex: flat[i],
      baseOffset: flat[i + 1],
      extentIndex: flat[i + 2],
      extentOffset: flat[i + 3],
    );
  }

  @override
  void operator []=(int index, CodeLineSelection value) =>
      throw UnsupportedError('read-only');

  int startLineOf(int index) => flat[index * 4];

  /// The first match starting at or after `line:offset`; [length] when none.
  int firstAtOrAfter(int line, int offset) {
    var low = 0;
    var high = length;
    while (low < high) {
      final mid = (low + high) >> 1;
      final i = mid * 4;
      final before =
          flat[i] < line || (flat[i] == line && flat[i + 1] < offset);
      if (before) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}
