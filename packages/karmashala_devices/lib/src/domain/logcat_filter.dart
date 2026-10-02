import 'logcat_entry.dart';
import 'logcat_tail.dart';

// The same model as the Flutter console's `app_log_filter.dart`, over logcat
// entries. Copied rather than shared: the two packages have no local
// dependency in common that a log filter belongs in (`karmashala_flutter_apps`
// is pure Dart, so it cannot reach `karmashala_ui`, and `agent_cli` must stay
// publishable), and the owner's package rule is to copy a small helper rather
// than add a dependency for it. Keep the two in step.

/// What the logcat view is asked to show. Filters ([levels], [tags]) always
/// hide; [text] only highlights unless [onlyMatching] is on.
class LogcatQuery {
  const LogcatQuery({
    this.text = '',
    this.regex = false,
    this.caseSensitive = false,
    this.onlyMatching = false,
    this.levels = const <LogLevel>{},
    this.tags = const <String>{},
  });

  final String text;
  final bool regex;
  final bool caseSensitive;
  final bool onlyMatching;

  /// Empty means every level. Multi-select, not a minimum: "errors and
  /// warnings from this tag" and "only debug" are both asked for.
  final Set<LogLevel> levels;

  /// Empty means every tag.
  final Set<String> tags;

  bool get isFiltered => levels.isNotEmpty || tags.isNotEmpty;

  LogcatQuery copyWith({
    String? text,
    bool? regex,
    bool? caseSensitive,
    bool? onlyMatching,
    Set<LogLevel>? levels,
    Set<String>? tags,
  }) => LogcatQuery(
    text: text ?? this.text,
    regex: regex ?? this.regex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    onlyMatching: onlyMatching ?? this.onlyMatching,
    levels: levels ?? this.levels,
    tags: tags ?? this.tags,
  );

  @override
  bool operator ==(Object other) =>
      other is LogcatQuery &&
      other.text == text &&
      other.regex == regex &&
      other.caseSensitive == caseSensitive &&
      other.onlyMatching == onlyMatching &&
      _sameSet(other.levels, levels) &&
      _sameSet(other.tags, tags);

  @override
  int get hashCode => Object.hash(
    text,
    regex,
    caseSensitive,
    onlyMatching,
    Object.hashAllUnordered(levels),
    Object.hashAllUnordered(tags),
  );
}

bool _sameSet<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);

/// The text an entry is searched and highlighted in — what the view draws
/// beside the level column.
String logcatSearchText(LogcatEntry entry) => '${entry.tag}: ${entry.message}';

/// A compiled search. An invalid regular expression is an [error], never a
/// throw, and matches nothing.
class LogcatPattern {
  LogcatPattern._(this._regExp, this.error);

  factory LogcatPattern.compile(LogcatQuery query) {
    if (query.text.isEmpty) return LogcatPattern._(null, null);
    try {
      return LogcatPattern._(
        RegExp(
          query.regex ? query.text : RegExp.escape(query.text),
          caseSensitive: query.caseSensitive,
          multiLine: true,
        ),
        null,
      );
    } on FormatException catch (e) {
      return LogcatPattern._(null, e.message);
    }
  }

  final RegExp? _regExp;

  /// Why the pattern did not compile.
  final String? error;

  /// Nothing to search for, or nothing that compiled.
  bool get isEmpty => _regExp == null;

  /// Non-empty matches only: `a*` must not make every line a match.
  bool hasMatch(String text) {
    final regExp = _regExp;
    if (regExp == null) return false;
    for (final m in regExp.allMatches(text)) {
      if (m.end > m.start) return true;
    }
    return false;
  }

  /// `[start, end)` of each non-empty match, in order.
  List<(int, int)> ranges(String text) {
    final regExp = _regExp;
    if (regExp == null) return const [];
    return [
      for (final m in regExp.allMatches(text))
        if (m.end > m.start) (m.start, m.end),
    ];
  }
}

/// Whether [entry] survives the query's level and tag filters.
bool passesLogcatFilters(LogcatEntry entry, LogcatQuery query) =>
    (query.levels.isEmpty || query.levels.contains(entry.level)) &&
    (query.tags.isEmpty || query.tags.contains(entry.tag));

/// One shown line and its tail sequence number.
class LogcatLine {
  const LogcatLine(this.sequence, this.entry, {this.isMatch = false});

  final int sequence;
  final LogcatEntry entry;
  final bool isMatch;
}

/// The view after a query: the lines to show, which of them match, and counts
/// taken before any filter so a chip can say what it would add.
class LogcatFilterResult {
  LogcatFilterResult({
    required this.query,
    required this.pattern,
    required this.lines,
    required this.matches,
    required this.total,
    required this.levelCounts,
    required this.tagCounts,
  });

  final LogcatQuery query;
  final LogcatPattern pattern;

  /// Oldest first.
  final List<LogcatLine> lines;

  /// Sequence numbers of matching lines, oldest first.
  final List<int> matches;

  /// Entries considered, before filters.
  final int total;
  final Map<LogLevel, int> levelCounts;
  final Map<String, int> tagCounts;

  String? get patternError => pattern.error;

  int countOf(LogLevel level) => levelCounts[level] ?? 0;

  /// Index into [lines] of [sequence], or -1.
  int indexOfLine(int sequence) {
    final i = _lowerBound(lines.length, (i) => lines[i].sequence, sequence);
    return i < lines.length && lines[i].sequence == sequence ? i : -1;
  }

  /// Index into [matches] of [sequence], or -1.
  int indexOfMatch(int sequence) {
    final i = _lowerBound(matches.length, (i) => matches[i], sequence);
    return i < matches.length && matches[i] == sequence ? i : -1;
  }

  /// The newest [limit] lines numbered at most [endSequence] (null: newest).
  List<LogcatLine> window({int? endSequence, required int limit}) {
    final end = endSequence == null
        ? lines.length
        : _lowerBound(lines.length, (i) => lines[i].sequence, endSequence + 1);
    final start = end - limit < 0 ? 0 : end - limit;
    return lines.sublist(start, end);
  }

  /// Lines newer than [sequence].
  int newerThan(int sequence) =>
      lines.length -
      _lowerBound(lines.length, (i) => lines[i].sequence, sequence + 1);
}

/// First index whose key is >= [target].
int _lowerBound(int length, int Function(int) keyAt, int target) {
  var lo = 0;
  var hi = length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (keyAt(mid) < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Filters [entries], numbered from [firstSequence]. Pure.
LogcatFilterResult filterLogcat(
  List<LogcatEntry> entries,
  LogcatQuery query, {
  int firstSequence = 0,
}) {
  final pattern = LogcatPattern.compile(query);
  final lines = <LogcatLine>[];
  final matches = <int>[];
  _filterInto(entries, query, pattern, firstSequence, lines, matches);
  return _withCounts(entries, query, pattern, lines, matches);
}

void _filterInto(
  List<LogcatEntry> entries,
  LogcatQuery query,
  LogcatPattern pattern,
  int firstSequence,
  List<LogcatLine> lines,
  List<int> matches,
) {
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (!passesLogcatFilters(entry, query)) continue;
    final isMatch = pattern.hasMatch(logcatSearchText(entry));
    // A pattern still being typed into a broken regex hides nothing.
    if (query.onlyMatching && !isMatch && !pattern.isEmpty) continue;
    final sequence = firstSequence + i;
    lines.add(LogcatLine(sequence, entry, isMatch: isMatch));
    if (isMatch) matches.add(sequence);
  }
}

LogcatFilterResult _withCounts(
  List<LogcatEntry> entries,
  LogcatQuery query,
  LogcatPattern pattern,
  List<LogcatLine> lines,
  List<int> matches,
) {
  final levels = <LogLevel, int>{};
  final tags = <String, int>{};
  for (final entry in entries) {
    levels[entry.level] = (levels[entry.level] ?? 0) + 1;
    tags[entry.tag] = (tags[entry.tag] ?? 0) + 1;
  }
  return LogcatFilterResult(
    query: query,
    pattern: pattern,
    lines: List.unmodifiable(lines),
    matches: List.unmodifiable(matches),
    total: entries.length,
    levelCounts: Map.unmodifiable(levels),
    tagCounts: Map.unmodifiable(tags),
  );
}

/// Keeps one [LogcatFilterResult] current against a growing tail: a flush
/// searches only the entries added since, and an unchanged tail and query
/// return the previous result itself.
class LogcatFilterCache {
  LogcatFilterResult? _result;
  LogcatTail? _tail;
  int _appended = 0;
  int _hideBefore = 0;
  int _firstSequence = 0;

  /// Entries run through the filters and the pattern, ever. For cost tests.
  int entriesSearched = 0;

  LogcatFilterResult update(
    LogcatTail tail,
    LogcatQuery query, {
    int hideBefore = 0,
  }) {
    final previous = _result;
    final from = tail.firstSequence > hideBefore
        ? tail.firstSequence
        : hideBefore;
    final sameView =
        previous != null &&
        identical(_tail, tail) &&
        previous.query == query &&
        _hideBefore == hideBefore &&
        _appended <= tail.appended &&
        // Nothing between the last reading and now was dropped unread.
        tail.firstSequence <= _appended;
    // A clear with nothing after it moves only the oldest held line.
    if (sameView &&
        _appended == tail.appended &&
        _firstSequence == tail.firstSequence) {
      return previous;
    }

    final entries = tail.since(from);
    final LogcatFilterResult result;
    if (sameView) {
      final added = tail.since(_appended);
      final lines = <LogcatLine>[
        for (final line in previous.lines)
          if (line.sequence >= from) line,
      ];
      final matches = <int>[
        for (final sequence in previous.matches)
          if (sequence >= from) sequence,
      ];
      entriesSearched += added.length;
      _filterInto(added, query, previous.pattern, _appended, lines, matches);
      result = _withCounts(entries, query, previous.pattern, lines, matches);
    } else {
      entriesSearched += entries.length;
      result = filterLogcat(entries, query, firstSequence: from);
    }
    _result = result;
    _tail = tail;
    _appended = tail.appended;
    _firstSequence = tail.firstSequence;
    _hideBefore = hideBefore;
    return result;
  }
}
