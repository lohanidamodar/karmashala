/// The one matching rule every search box uses: case and word separators do
/// not matter, so "appwrite ai", "appwrite-ai", "appwrite_ai" and "appwriteAi"
/// are the same query, and the query's words must appear in the text in order.
library;

/// What a query matched in one piece of text.
class SearchMatch {
  const SearchMatch({required this.score, required this.positions});

  /// Higher is better. Unbounded above; only comparisons are meaningful.
  final double score;

  /// Indexes into the original text that the query consumed, ascending, for
  /// highlighting.
  final List<int> positions;
}

/// Whether [query] finds [text]. A blank query finds everything.
bool matchesSearch(String query, String? text) =>
    text != null && searchMatch(query, text) != null;

/// Whether [query] finds any of [texts].
bool matchesSearchAny(String query, Iterable<String?> texts) {
  final q = _Folded(query);
  if (q.isEmpty) return true;
  return texts.any((text) => text != null && _match(q, text, false) != null);
}

/// Scores [query] against [text], or null when it does not match. With
/// [initials], a query whose words are not found may still match as scattered
/// characters in order ("aaw" finds "appwrite-ai-workdir"), ranked below any
/// found word.
SearchMatch? searchMatch(String query, String text, {bool initials = false}) =>
    _match(_Folded(query), text, initials);

SearchMatch? _match(_Folded query, String text, bool initials) {
  if (query.isEmpty) return const SearchMatch(score: 0, positions: []);
  final haystack = _Folded(text);
  if (haystack.isEmpty) return null;
  return _words(query, haystack, preferWordStarts: true) ??
      _words(query, haystack, preferWordStarts: false) ??
      (initials ? _scattered(query, haystack) : null);
}

/// Separators: what a name is spelled with between its words.
bool _isSeparator(int c) =>
    c == 0x20 || // space
    c == 0x09 ||
    c == 0x0A ||
    c == 0x2F || // /
    c == 0x5C || // \
    c == 0x5F || // _
    c == 0x2D || // -
    c == 0x2E || // .
    c == 0x3A || // :
    c == 0x2C || // ,
    c == 0x3B || // ;
    c == 0x28 || // (
    c == 0x29 ||
    c == 0x5B || // [
    c == 0x5D ||
    c == 0x7B || // {
    c == 0x7D ||
    c == 0x27 || // '
    c == 0x22 || // "
    c == 0x7C; // |

bool _isUpper(int c) => c >= 0x41 && c <= 0x5A;
bool _isLower(int c) => c >= 0x61 && c <= 0x7A;

/// [text] lowercased with its separators dropped, remembering where each kept
/// character came from and which ones begin a word.
class _Folded {
  _Folded(String text) : originalLength = text.length {
    final buffer = StringBuffer();
    final lower = text.toLowerCase();
    var afterSeparator = true;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (_isSeparator(c)) {
        afterSeparator = true;
        continue;
      }
      var start = afterSeparator;
      if (!start && i > 0) {
        final previous = text.codeUnitAt(i - 1);
        // A camelCase hump, or the last capital of an acronym before a word:
        // the `W` of `AIWorkdir`.
        start =
            (_isUpper(c) && _isLower(previous)) ||
            (_isUpper(c) &&
                _isUpper(previous) &&
                i + 1 < text.length &&
                _isLower(text.codeUnitAt(i + 1)));
      }
      buffer.writeCharCode(lower.codeUnitAt(i));
      origins.add(i);
      wordStarts.add(start);
      afterSeparator = false;
    }
    folded = buffer.toString();
  }

  late final String folded;
  final int originalLength;
  final origins = <int>[];
  final wordStarts = <bool>[];

  /// The words, folded, in order.
  late final List<String> words = [
    for (var i = 0; i < folded.length; i++)
      if (wordStarts[i]) folded.substring(i, _nextStart(i + 1)),
  ];

  bool get isEmpty => folded.isEmpty;
  int get length => folded.length;

  bool startsWord(int i) => i < wordStarts.length && wordStarts[i];
  bool endsWord(int end) => end >= folded.length || wordStarts[end];

  int _nextStart(int from) {
    for (var i = from; i < folded.length; i++) {
      if (wordStarts[i]) return i;
    }
    return folded.length;
  }
}

const _perChar = 38.0;
const _exactBonus = 420.0;
const _firstAtStartBonus = 240.0;
const _wordStartBonus = 150.0;
const _wholeWordBonus = 60.0;
const _leadingGapPenalty = 1.6;
const _innerGapPenalty = 1.2;

/// The longest a text can be before its length stops counting against it, so a
/// deeply nested path can still outrank a short one.
const _lengthPenaltyCap = 60.0;

double _lengthPenalty(int length) =>
    (length > _lengthPenaltyCap ? _lengthPenaltyCap : length.toDouble()) * 0.8;

/// Each query word found in turn, after the previous one.
SearchMatch? _words(
  _Folded query,
  _Folded text, {
  required bool preferWordStarts,
}) {
  final positions = <int>[];
  var score = 0.0;
  var cursor = 0;
  for (var w = 0; w < query.words.length; w++) {
    final word = query.words[w];
    var at = text.folded.indexOf(word, cursor);
    if (at < 0) return null;
    if (preferWordStarts) {
      var start = at;
      while (start >= 0 && !text.startsWord(start)) {
        start = text.folded.indexOf(word, start + 1);
      }
      if (start < 0) return null;
      at = start;
    }
    final end = at + word.length;
    score += word.length * _perChar;
    if (text.startsWord(at)) {
      score += w == 0 && at == 0 ? _firstAtStartBonus : _wordStartBonus;
      if (text.endsWord(end)) score += _wholeWordBonus;
    }
    score -= (w == 0
        ? at * _leadingGapPenalty
        : (at - cursor) * _innerGapPenalty);
    for (var i = at; i < end; i++) {
      positions.add(text.origins[i]);
    }
    cursor = end;
  }
  // Topped up to the exact bonus rather than stacked on the first word's, so an
  // exact subtitle cannot outrank a word in a title.
  if (query.folded == text.folded) {
    score += _exactBonus - _firstAtStartBonus - _wholeWordBonus;
  }
  score -= _lengthPenalty(text.originalLength);
  return SearchMatch(score: score, positions: positions);
}

const _scatteredChar = 12.0;
const _scatteredConsecutive = 26.0;
const _scatteredWordStart = 34.0;
const _scatteredGapPenalty = 2.2;

/// The query's characters in order, each preferring a word start.
SearchMatch? _scattered(_Folded query, _Folded text) {
  final positions = <int>[];
  var score = 0.0;
  var cursor = 0;
  var previous = -2;
  final needle = query.folded;
  final haystack = text.folded;
  for (var q = 0; q < needle.length; q++) {
    final target = needle.codeUnitAt(q);
    var found = -1;
    var fallback = -1;
    for (var i = cursor; i < haystack.length; i++) {
      if (haystack.codeUnitAt(i) != target) continue;
      if (fallback < 0) fallback = i;
      if (i == previous + 1 || text.startsWord(i)) {
        found = i;
        break;
      }
    }
    if (found < 0) found = fallback;
    if (found < 0) return null;

    score += _scatteredChar;
    if (found == previous + 1) {
      score += _scatteredConsecutive;
    } else if (previous >= 0) {
      score -= (found - previous - 1) * _scatteredGapPenalty;
    }
    if (text.startsWord(found)) score += _scatteredWordStart;
    if (q == 0) score -= found * _leadingGapPenalty;

    positions.add(text.origins[found]);
    previous = found;
    cursor = found + 1;
  }
  score -= _lengthPenalty(text.originalLength);
  return SearchMatch(score: score, positions: positions);
}
