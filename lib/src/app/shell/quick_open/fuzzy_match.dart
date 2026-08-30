/// Fuzzy matching and scoring for quick open.
///
/// Pure: no widgets, no providers, no clock. One surface has to rank a session
/// title, a file path, a branch name and a command against the same query, so
/// the ranking must be a function of the text alone — anything that needs to
/// know *what kind* of thing it is scoring belongs to the caller, as a per-item
/// weight.
library;

/// What a query matched in one piece of text.
class FuzzyMatch {
  const FuzzyMatch({required this.score, required this.positions});

  /// Higher is better. Unbounded above; only comparisons are meaningful.
  final double score;

  /// Indexes into the haystack that the query consumed, ascending. Used to
  /// bold the matched characters, so the user can see *why* a row is there.
  final List<int> positions;
}

/// Characters after which the next character starts a new word. Paths, branch
/// names, and command labels are all word-separated by one of these, which is
/// why `gso` finds `git status --oneline` and `apsh` finds `app_shell.dart`.
bool _isSeparator(int code) =>
    code == 0x20 || // space
    code == 0x2F || // /
    code == 0x5C || // \
    code == 0x5F || // _
    code == 0x2D || // -
    code == 0x2E || // .
    code == 0x3A || // :
    code == 0x2C || // ,
    code == 0x28 || // (
    code == 0x5B; // [

bool _isUpper(int code) => code >= 0x41 && code <= 0x5A;
bool _isLower(int code) => code >= 0x61 && code <= 0x7A;

/// Whether the character at [index] of [text] begins a word — the start of the
/// string, anything after a separator, or a camelCase hump.
bool _startsWord(String text, int index) {
  if (index == 0) return true;
  final previous = text.codeUnitAt(index - 1);
  if (_isSeparator(previous)) return true;
  final current = text.codeUnitAt(index);
  return _isUpper(current) && _isLower(previous);
}

const _matchedChar = 12.0;
const _wordStartBonus = 34.0;
const _consecutiveBonus = 26.0;
const _leadingGapPenalty = 1.6;
const _innerGapPenalty = 2.2;

/// The longest a haystack can be before its length stops counting against it.
/// Without a cap a deeply nested path could never outrank a short one even on
/// an exact filename match.
const _lengthPenaltyCap = 60.0;

/// Scores [query] against [text], or returns null when [text] does not contain
/// [query]'s characters in order.
///
/// Two passes, because they answer different questions and users expect both:
///
/// * a **substring** hit (`login` in `Fix login bug`) is the common case and
///   should always beat a scattered subsequence hit of the same query;
/// * a **subsequence** hit (`fxlgn`) is what makes an abbreviation work.
///
/// An empty query matches everything with score 0, so "what is here?" is a
/// legal question and the caller decides what to show for it.
FuzzyMatch? fuzzyMatch(String query, String text) {
  if (query.isEmpty) return const FuzzyMatch(score: 0, positions: []);
  if (text.isEmpty) return null;

  final haystack = text.toLowerCase();
  final needle = query.toLowerCase();

  final substring = haystack.indexOf(needle);
  if (substring >= 0) {
    return FuzzyMatch(
      score: _substringScore(text, haystack, needle, substring),
      positions: [for (var i = 0; i < needle.length; i++) substring + i],
    );
  }
  return _subsequence(text, haystack, needle);
}

double _substringScore(String text, String haystack, String needle, int at) {
  var score = needle.length * _matchedChar + needle.length * _consecutiveBonus;
  if (haystack == needle) {
    score += 420;
  } else if (at == 0) {
    score += 240;
  } else if (_startsWord(text, at)) {
    score += 150;
  }
  score -= at * _leadingGapPenalty;
  score -= _lengthPenalty(haystack.length);
  return score;
}

FuzzyMatch? _subsequence(String text, String haystack, String needle) {
  final positions = <int>[];
  var score = 0.0;
  var cursor = 0;
  var previous = -2;

  for (var q = 0; q < needle.length; q++) {
    final target = needle.codeUnitAt(q);
    var found = -1;
    // Prefer a word-start occurrence over the first occurrence: for `apsh` in
    // `app_shell.dart` the `sh` must land on `shell`, not on the `s` that never
    // comes. Scan forward for a word start, and fall back to the nearest hit.
    var fallback = -1;
    for (var i = cursor; i < haystack.length; i++) {
      if (haystack.codeUnitAt(i) != target) continue;
      if (fallback < 0) fallback = i;
      if (i == previous + 1 || _startsWord(text, i)) {
        found = i;
        break;
      }
    }
    if (found < 0) found = fallback;
    if (found < 0) return null;

    score += _matchedChar;
    if (found == previous + 1) {
      score += _consecutiveBonus;
    } else if (previous >= 0) {
      score -= (found - previous - 1) * _innerGapPenalty;
    }
    if (_startsWord(text, found)) score += _wordStartBonus;
    if (q == 0) score -= found * _leadingGapPenalty;

    positions.add(found);
    previous = found;
    cursor = found + 1;
  }

  score -= _lengthPenalty(haystack.length);
  return FuzzyMatch(score: score, positions: positions);
}

double _lengthPenalty(int length) =>
    (length > _lengthPenaltyCap ? _lengthPenaltyCap : length.toDouble()) * 0.8;
