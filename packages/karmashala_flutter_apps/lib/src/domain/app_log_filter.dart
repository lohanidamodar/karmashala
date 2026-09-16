import 'app_log_record.dart';

/// The console's filter groups: what a reader asks for, not the four VM
/// service streams — stderr and a framework error are both "errors".
enum AppLogChannel {
  output,
  errors,
  logs,
  lifecycle;

  static AppLogChannel of(AppLogSource source) => switch (source) {
    AppLogSource.stdout => output,
    AppLogSource.stderr || AppLogSource.flutterError => errors,
    AppLogSource.developerLog => logs,
    AppLogSource.lifecycle => lifecycle,
  };
}

/// What the console is asked to show. Filters ([channels], [loggerNames])
/// always hide; [text] only highlights unless [onlyMatching] is on.
class AppLogQuery {
  const AppLogQuery({
    this.text = '',
    this.regex = false,
    this.caseSensitive = false,
    this.onlyMatching = false,
    this.channels = const <AppLogChannel>{},
    this.loggerNames = const <String>{},
  });

  final String text;
  final bool regex;
  final bool caseSensitive;
  final bool onlyMatching;

  /// Empty means every channel.
  final Set<AppLogChannel> channels;

  /// Developer logs from these loggers only; empty means all of them. A record
  /// with no logger name is filed under `''`. Never hides a non-log line.
  final Set<String> loggerNames;

  bool get isFiltered => channels.isNotEmpty || loggerNames.isNotEmpty;

  AppLogQuery copyWith({
    String? text,
    bool? regex,
    bool? caseSensitive,
    bool? onlyMatching,
    Set<AppLogChannel>? channels,
    Set<String>? loggerNames,
  }) => AppLogQuery(
    text: text ?? this.text,
    regex: regex ?? this.regex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    onlyMatching: onlyMatching ?? this.onlyMatching,
    channels: channels ?? this.channels,
    loggerNames: loggerNames ?? this.loggerNames,
  );

  @override
  bool operator ==(Object other) =>
      other is AppLogQuery &&
      other.text == text &&
      other.regex == regex &&
      other.caseSensitive == caseSensitive &&
      other.onlyMatching == onlyMatching &&
      _sameSet(other.channels, channels) &&
      _sameSet(other.loggerNames, loggerNames);

  @override
  int get hashCode => Object.hash(
    text,
    regex,
    caseSensitive,
    onlyMatching,
    Object.hashAllUnordered(channels),
    Object.hashAllUnordered(loggerNames),
  );
}

bool _sameSet<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);

/// The text a record is searched and highlighted in — what the console draws.
String appLogSearchText(AppLogRecord record) => record.detail == null
    ? record.message
    : '${record.message}\n${record.detail}';

/// A compiled search. An invalid regular expression is an [error], never a
/// throw, and matches nothing.
class AppLogPattern {
  AppLogPattern._(this._regExp, this.error);

  factory AppLogPattern.compile(AppLogQuery query) {
    if (query.text.isEmpty) return AppLogPattern._(null, null);
    try {
      return AppLogPattern._(
        RegExp(
          query.regex ? query.text : RegExp.escape(query.text),
          caseSensitive: query.caseSensitive,
          multiLine: true,
        ),
        null,
      );
    } on FormatException catch (e) {
      return AppLogPattern._(null, e.message);
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

/// Whether [record] survives the query's channel and logger filters.
bool passesAppLogFilters(AppLogRecord record, AppLogQuery query) {
  if (query.channels.isNotEmpty &&
      !query.channels.contains(AppLogChannel.of(record.source))) {
    return false;
  }
  if (query.loggerNames.isNotEmpty &&
      record.source == AppLogSource.developerLog &&
      !query.loggerNames.contains(record.loggerName ?? '')) {
    return false;
  }
  return true;
}

/// One shown line and its buffer sequence number.
class AppLogLine {
  const AppLogLine(this.sequence, this.record, {this.isMatch = false});

  final int sequence;
  final AppLogRecord record;
  final bool isMatch;
}

/// The console after a query: the lines to show, which of them match, and
/// counts taken before any filter so a chip can say what it would add.
class AppLogFilterResult {
  AppLogFilterResult({
    required this.query,
    required this.pattern,
    required this.lines,
    required this.matches,
    required this.total,
    required this.channelCounts,
    required this.loggerCounts,
    this.newestError,
  });

  final AppLogQuery query;
  final AppLogPattern pattern;

  /// Oldest first.
  final List<AppLogLine> lines;

  /// Sequence numbers of matching lines, oldest first.
  final List<int> matches;

  /// Records considered, before filters.
  final int total;
  final Map<AppLogChannel, int> channelCounts;

  /// Developer logs per logger name, `''` for unnamed.
  final Map<String, int> loggerCounts;
  final AppLogRecord? newestError;

  String? get patternError => pattern.error;

  int countOf(AppLogChannel channel) => channelCounts[channel] ?? 0;

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
  List<AppLogLine> window({int? endSequence, required int limit}) {
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

/// Filters [records], numbered from [firstSequence]. Pure.
AppLogFilterResult filterRecords(
  List<AppLogRecord> records,
  AppLogQuery query, {
  int firstSequence = 0,
}) {
  final pattern = AppLogPattern.compile(query);
  final lines = <AppLogLine>[];
  final matches = <int>[];
  _filterInto(records, query, pattern, firstSequence, lines, matches);
  return _withCounts(records, query, pattern, lines, matches);
}

void _filterInto(
  List<AppLogRecord> records,
  AppLogQuery query,
  AppLogPattern pattern,
  int firstSequence,
  List<AppLogLine> lines,
  List<int> matches,
) {
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    if (!passesAppLogFilters(record, query)) continue;
    final isMatch = pattern.hasMatch(appLogSearchText(record));
    // A pattern still being typed into a broken regex hides nothing.
    if (query.onlyMatching && !isMatch && !pattern.isEmpty) continue;
    final sequence = firstSequence + i;
    lines.add(AppLogLine(sequence, record, isMatch: isMatch));
    if (isMatch) matches.add(sequence);
  }
}

AppLogFilterResult _withCounts(
  List<AppLogRecord> records,
  AppLogQuery query,
  AppLogPattern pattern,
  List<AppLogLine> lines,
  List<int> matches,
) {
  final channels = <AppLogChannel, int>{};
  final loggers = <String, int>{};
  AppLogRecord? newestError;
  for (final record in records) {
    final channel = AppLogChannel.of(record.source);
    channels[channel] = (channels[channel] ?? 0) + 1;
    if (record.source == AppLogSource.developerLog) {
      final name = record.loggerName ?? '';
      loggers[name] = (loggers[name] ?? 0) + 1;
    }
    if (record.isError) newestError = record;
  }
  return AppLogFilterResult(
    query: query,
    pattern: pattern,
    lines: List.unmodifiable(lines),
    matches: List.unmodifiable(matches),
    total: records.length,
    channelCounts: Map.unmodifiable(channels),
    loggerCounts: Map.unmodifiable(loggers),
    newestError: newestError,
  );
}

/// Keeps one [AppLogFilterResult] current against a growing buffer: a tick
/// searches only the records added since, and an unchanged buffer and query
/// return the previous result itself.
class AppLogFilterCache {
  AppLogFilterResult? _result;
  AppLogBuffer? _buffer;
  int _appended = 0;
  int _hideBefore = 0;

  /// Records run through the filters and the pattern, ever. For cost tests.
  int recordsSearched = 0;

  AppLogFilterResult update(
    AppLogBuffer buffer,
    AppLogQuery query, {
    int hideBefore = 0,
  }) {
    final previous = _result;
    final from = buffer.firstSequence > hideBefore
        ? buffer.firstSequence
        : hideBefore;
    final sameView =
        previous != null &&
        identical(_buffer, buffer) &&
        previous.query == query &&
        _hideBefore == hideBefore &&
        _appended <= buffer.appended &&
        // Nothing between the last reading and now was dropped unread.
        buffer.firstSequence <= _appended;
    if (sameView && _appended == buffer.appended) return previous;

    final records = buffer.since(from);
    final AppLogFilterResult result;
    if (sameView) {
      final added = buffer.since(_appended);
      final lines = <AppLogLine>[
        for (final line in previous.lines)
          if (line.sequence >= from) line,
      ];
      final matches = <int>[
        for (final sequence in previous.matches)
          if (sequence >= from) sequence,
      ];
      recordsSearched += added.length;
      _filterInto(added, query, previous.pattern, _appended, lines, matches);
      result = _withCounts(records, query, previous.pattern, lines, matches);
    } else {
      recordsSearched += records.length;
      result = filterRecords(records, query, firstSequence: from);
    }
    _result = result;
    _buffer = buffer;
    _appended = buffer.appended;
    _hideBefore = hideBefore;
    return result;
  }
}
