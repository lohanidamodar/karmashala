import 'package:karmashala_devices/devices.dart';
import 'package:test/test.dart';

LogcatEntry _e(
  String message, {
  LogLevel level = LogLevel.info,
  String tag = 'App',
}) => LogcatEntry(
  timestamp: '09-17 10:15:33.123',
  pid: 1,
  tid: 1,
  level: level,
  tag: tag,
  message: message,
);

List<String> _shown(LogcatFilterResult result) => [
  for (final line in result.lines) line.entry.message,
];

/// Mirrors `karmashala_flutter_apps/test/app_log_filter_test.dart`: the two
/// log views share one search and filter model.
void main() {
  final entries = [
    _e('Hello World'),
    _e('boom', level: LogLevel.error, tag: 'AndroidRuntime'),
    _e('net up', level: LogLevel.debug, tag: 'net'),
    _e('db ready', level: LogLevel.debug, tag: 'db'),
    _e('slow frame', level: LogLevel.warning, tag: 'Choreographer'),
    _e('verbose chatter', level: LogLevel.verbose, tag: 'net'),
    _e('fatal: hello', level: LogLevel.fatal, tag: 'libc'),
  ];

  group('filterLogcat', () {
    test('an empty query shows everything and matches nothing', () {
      final result = filterLogcat(entries, const LogcatQuery());
      expect(result.lines, hasLength(entries.length));
      expect(result.matches, isEmpty);
      expect(result.patternError, isNull);
    });

    test('substring search is case-insensitive by default and highlights '
        'without hiding', () {
      final result = filterLogcat(entries, const LogcatQuery(text: 'HELLO'));
      expect(result.lines, hasLength(entries.length));
      expect(result.matches, [0, 6]);
      expect(result.pattern.ranges('say hello, Hello'), [(4, 9), (11, 16)]);
    });

    test('the tag is searched too: it is drawn beside the message', () {
      final result = filterLogcat(
        entries,
        const LogcatQuery(text: 'androidruntime'),
      );
      expect(result.matches, [1]);
      expect(logcatSearchText(entries[1]), 'AndroidRuntime: boom');
    });

    test('match case narrows it', () {
      final result = filterLogcat(
        entries,
        const LogcatQuery(text: 'Hello', caseSensitive: true),
      );
      expect(result.matches, [0]);
    });

    test('substring treats regex characters literally', () {
      final result = filterLogcat([
        _e('a.b'),
        _e('axb'),
      ], const LogcatQuery(text: 'a.b'));
      expect(result.matches, [0]);
    });

    test('regex search', () {
      final result = filterLogcat(
        entries,
        const LogcatQuery(text: r'^(net|db):', regex: true),
      );
      expect(result.matches, [2, 3, 5]);
    });

    test(
      'an invalid regex is reported, matches nothing, and hides nothing',
      () {
        late LogcatFilterResult result;
        expect(
          () => result = filterLogcat(
            entries,
            const LogcatQuery(
              text: '(unclosed',
              regex: true,
              onlyMatching: true,
            ),
          ),
          returnsNormally,
        );
        expect(result.patternError, isNotNull);
        expect(result.matches, isEmpty);
        expect(result.lines, hasLength(entries.length));
      },
    );

    test(
      'a pattern that matches the empty string does not match every line',
      () {
        final result = filterLogcat(
          entries,
          const LogcatQuery(text: 'z*', regex: true),
        );
        expect(result.matches, isEmpty);
      },
    );

    test('only matching lines hides the rest', () {
      final result = filterLogcat(
        entries,
        const LogcatQuery(text: 'ready|up', regex: true, onlyMatching: true),
      );
      expect(_shown(result), ['net up', 'db ready']);
    });

    test('levels are multi-select, not a minimum', () {
      expect(
        _shown(
          filterLogcat(
            entries,
            const LogcatQuery(levels: {LogLevel.error, LogLevel.fatal}),
          ),
        ),
        ['boom', 'fatal: hello'],
      );
      expect(
        _shown(
          filterLogcat(
            entries,
            const LogcatQuery(levels: {LogLevel.debug, LogLevel.warning}),
          ),
        ),
        ['net up', 'db ready', 'slow frame'],
      );
    });

    test('tags narrow, and combine with levels', () {
      expect(
        _shown(filterLogcat(entries, const LogcatQuery(tags: {'net', 'db'}))),
        ['net up', 'db ready', 'verbose chatter'],
      );
      expect(
        _shown(
          filterLogcat(
            entries,
            const LogcatQuery(tags: {'net'}, levels: {LogLevel.verbose}),
          ),
        ),
        ['verbose chatter'],
      );
    });

    test('counts are taken before filters', () {
      final result = filterLogcat(
        entries,
        const LogcatQuery(levels: {LogLevel.info}, text: 'nothing'),
      );
      expect(result.countOf(LogLevel.verbose), 1);
      expect(result.countOf(LogLevel.debug), 2);
      expect(result.countOf(LogLevel.info), 1);
      expect(result.countOf(LogLevel.warning), 1);
      expect(result.countOf(LogLevel.error), 1);
      expect(result.countOf(LogLevel.fatal), 1);
      expect(result.tagCounts['net'], 2);
      expect(result.total, entries.length);
    });

    test('windows and sequence lookups', () {
      final many = [for (var i = 0; i < 10; i++) _e('line $i')];
      final result = filterLogcat(
        many,
        const LogcatQuery(text: 'line [13579]', regex: true),
        firstSequence: 100,
      );
      expect(result.window(limit: 3).map((l) => l.sequence), [107, 108, 109]);
      expect(result.window(endSequence: 104, limit: 3).map((l) => l.sequence), [
        102,
        103,
        104,
      ]);
      expect(result.newerThan(104), 5);
      expect(result.indexOfLine(105), 5);
      expect(result.indexOfLine(99), -1);
      expect(result.indexOfMatch(105), 2);
      expect(result.indexOfMatch(104), -1);
    });

    test('query equality ignores set order', () {
      expect(
        const LogcatQuery(levels: {LogLevel.error, LogLevel.warning}),
        const LogcatQuery(levels: {LogLevel.warning, LogLevel.error}),
      );
      expect(
        const LogcatQuery(tags: {'a'}),
        isNot(const LogcatQuery(tags: {'b'})),
      );
    });
  });

  group('LogcatTail sequence numbers', () {
    test('survive dropping and clearing', () {
      final tail = LogcatTail(capacity: 3);
      for (var i = 0; i < 5; i++) {
        tail.add(_e('line $i'));
      }
      expect(tail.appended, 5);
      expect(tail.firstSequence, 2);
      expect(tail.since(3).map((e) => e.message), ['line 3', 'line 4']);
      expect(tail.since(0), hasLength(3));
      expect(tail.since(9), isEmpty);
      tail.clear();
      expect(tail.firstSequence, 5);
    });
  });

  group('LogcatFilterCache', () {
    test('an unchanged tail and query return the same result', () {
      final tail = LogcatTail()..add(_e('a'));
      final cache = LogcatFilterCache();
      final first = cache.update(tail, const LogcatQuery(text: 'a'));
      expect(cache.update(tail, const LogcatQuery(text: 'a')), same(first));
      expect(cache.entriesSearched, 1);
    });

    test('a flush searches only what arrived', () {
      final tail = LogcatTail();
      final cache = LogcatFilterCache();
      for (var i = 0; i < 100; i++) {
        tail.add(_e('line $i'));
      }
      const query = LogcatQuery(text: 'line 9', onlyMatching: true);
      cache.update(tail, query);
      expect(cache.entriesSearched, 100);
      tail
        ..add(_e('line 900'))
        ..add(_e('other'));
      final result = cache.update(tail, query);
      expect(cache.entriesSearched, 102);
      expect(
        result.lines.map((l) => l.entry.message),
        filterLogcat(tail.entries, query).lines.map((l) => l.entry.message),
      );
      expect(result.matches.last, 100);
    });

    test('a new query searches again', () {
      final tail = LogcatTail()
        ..add(_e('a'))
        ..add(_e('b'));
      final cache = LogcatFilterCache();
      cache.update(tail, const LogcatQuery(text: 'a'));
      final result = cache.update(tail, const LogcatQuery(text: 'b'));
      expect(cache.entriesSearched, 4);
      expect(result.matches, [1]);
    });

    test('dropped lines leave the result and counts follow', () {
      final tail = LogcatTail(capacity: 3);
      final cache = LogcatFilterCache();
      tail
        ..add(_e('x1', level: LogLevel.error))
        ..add(_e('x2'))
        ..add(_e('x3'));
      cache.update(tail, const LogcatQuery(text: 'x'));
      tail.add(_e('x4'));
      final result = cache.update(tail, const LogcatQuery(text: 'x'));
      expect(result.lines.map((l) => l.sequence), [1, 2, 3]);
      expect(result.matches, [1, 2, 3]);
      expect(result.countOf(LogLevel.error), 0);
    });

    test('a gap wider than the tail searches the whole tail', () {
      final tail = LogcatTail(capacity: 2);
      final cache = LogcatFilterCache();
      tail.add(_e('a'));
      cache.update(tail, const LogcatQuery());
      for (var i = 0; i < 5; i++) {
        tail.add(_e('b$i'));
      }
      final result = cache.update(tail, const LogcatQuery());
      expect(result.lines.map((l) => l.sequence), [4, 5]);
    });

    test('a cleared tail empties the result, and numbering carries on', () {
      final tail = LogcatTail()
        ..add(_e('a'))
        ..add(_e('b'));
      final cache = LogcatFilterCache();
      cache.update(tail, const LogcatQuery());
      tail.clear();
      expect(cache.update(tail, const LogcatQuery()).lines, isEmpty);
      tail.add(_e('c'));
      final result = cache.update(tail, const LogcatQuery());
      expect(result.lines.single.sequence, 2);
    });

    test('hideBefore clears the view without touching the tail', () {
      final tail = LogcatTail()
        ..add(_e('old'))
        ..add(_e('older'));
      final cache = LogcatFilterCache();
      final cleared = cache.update(
        tail,
        const LogcatQuery(),
        hideBefore: tail.appended,
      );
      expect(cleared.lines, isEmpty);
      expect(cleared.total, 0);
      tail.add(_e('new'));
      final result = cache.update(tail, const LogcatQuery(), hideBefore: 2);
      expect(result.lines.single.entry.message, 'new');
      expect(tail.length, 3);
    });
  });
}
