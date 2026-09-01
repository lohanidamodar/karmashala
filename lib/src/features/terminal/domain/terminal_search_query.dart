/// What the find bar is looking for: literal text or a regular expression,
/// folded or not.
///
/// Compiled **once** per query rather than per line. A `RegExp` built inside the
/// scan loop would recompile the pattern for every line of a 10 000-line
/// scrollback, which is the whole cost of the search.
///
/// The two toggles **compose**: `caseSensitive` becomes `RegExp`'s own
/// `caseSensitive`, so `.*` and `Aa` are independent and either order of
/// pressing them gives the same result. Dart's `RegExp` has no inline `(?i)`
/// flag, so the toggle is the only way to fold a pattern's case — which is why
/// it stays enabled while regex is on rather than being greyed out.
class TerminalSearchQuery {
  TerminalSearchQuery._({
    required this.text,
    required this.caseSensitive,
    required this.isRegex,
    this.error,
    RegExp? compiled,
    String? folded,
  }) : _pattern = compiled,
       _needle = folded;

  /// Compiles [text]. An invalid pattern is **not** an exception and **not** a
  /// silent downgrade to literal matching: it comes back as a query that
  /// carries [error] and matches nothing, so the bar can say what is wrong
  /// while the user is still typing the rest of it.
  factory TerminalSearchQuery.parse(
    String text, {
    bool caseSensitive = false,
    bool regex = false,
  }) {
    if (!regex) {
      return TerminalSearchQuery._(
        text: text,
        caseSensitive: caseSensitive,
        isRegex: false,
        folded: caseSensitive ? text : text.toLowerCase(),
      );
    }
    try {
      return TerminalSearchQuery._(
        text: text,
        caseSensitive: caseSensitive,
        isRegex: true,
        compiled: RegExp(text, caseSensitive: caseSensitive),
      );
    } on FormatException catch (e) {
      return TerminalSearchQuery._(
        text: text,
        caseSensitive: caseSensitive,
        isRegex: true,
        error: _shortError(e),
      );
    }
  }

  final String text;
  final bool caseSensitive;
  final bool isRegex;

  /// Why the pattern would not compile, short enough for the find bar. Null for
  /// every literal query and for a pattern that compiled.
  final String? error;

  final RegExp? _pattern;

  /// The literal needle, already folded when the search is case-insensitive.
  final String? _needle;

  /// Whether this query can match anything at all. An empty query and a broken
  /// pattern are both "no", for the same reason: there is nothing to look for.
  bool get isUsable => text.isNotEmpty && error == null;

  /// Reports every hit in [haystack] as a half-open `[start, end)` range of
  /// **character** indices, in reading order.
  ///
  /// Callers map those to cell columns; see [TerminalLineText]. A hit never
  /// spans a line break, so `^` and `$` anchor to one buffer line.
  void forEachMatch(String haystack, void Function(int start, int end) onHit) {
    if (!isUsable || haystack.isEmpty) return;

    final pattern = _pattern;
    if (pattern != null) {
      for (final match in pattern.allMatches(haystack)) {
        // A zero-width hit — `x*` against "abc" — has no cells to highlight and
        // would put an unreachable entry in "3 of 40". `allMatches` already
        // advances past them, so skipping is all that is needed.
        if (match.end > match.start) onHit(match.start, match.end);
      }
      return;
    }

    final needle = _needle!;
    final folded = caseSensitive ? haystack : haystack.toLowerCase();
    var from = 0;
    while (true) {
      final at = folded.indexOf(needle, from);
      if (at < 0) return;
      onHit(at, at + needle.length);
      from = at + needle.length;
    }
  }

  /// `RegExp`'s message is "Invalid regular expression: /a(/: …" plus a caret
  /// diagram, which is three lines the bar has no room for.
  static String _shortError(FormatException e) {
    final first = e.message.split('\n').first.trim();
    return first.isEmpty ? 'Invalid pattern' : first;
  }
}
