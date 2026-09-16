import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:test/test.dart';

AppLogRecord _r(
  String message, {
  AppLogSource source = AppLogSource.stdout,
  String? logger,
  String? detail,
}) => AppLogRecord(
  source: source,
  at: DateTime.utc(2026, 9, 16),
  message: message,
  loggerName: logger,
  detail: detail,
);

List<String> _shown(AppLogFilterResult result) => [
  for (final line in result.lines) line.record.message,
];

void main() {
  final records = [
    _r('Hello World'),
    _r('boom', source: AppLogSource.stderr),
    _r('net up', source: AppLogSource.developerLog, logger: 'net'),
    _r('db ready', source: AppLogSource.developerLog, logger: 'db'),
    _r('anon', source: AppLogSource.developerLog),
    _r('Attached', source: AppLogSource.lifecycle),
    _r(
      'The following StateError',
      source: AppLogSource.flutterError,
      detail: 'Bad state: hello',
    ),
  ];

  group('filterRecords', () {
    test('an empty query shows everything and matches nothing', () {
      final result = filterRecords(records, const AppLogQuery());
      expect(result.lines, hasLength(records.length));
      expect(result.matches, isEmpty);
      expect(result.patternError, isNull);
    });

    test('substring search is case-insensitive by default and highlights '
        'without hiding', () {
      final result = filterRecords(records, const AppLogQuery(text: 'HELLO'));
      expect(result.lines, hasLength(records.length));
      // The detail is searched too: it is drawn under the message.
      expect(result.matches, [0, 6]);
      expect(result.pattern.ranges('say hello, Hello'), [(4, 9), (11, 16)]);
    });

    test('match case narrows it', () {
      final result = filterRecords(
        records,
        const AppLogQuery(text: 'Hello', caseSensitive: true),
      );
      expect(result.matches, [0]);
    });

    test('substring treats regex characters literally', () {
      final result = filterRecords([
        _r('a.b'),
        _r('axb'),
      ], const AppLogQuery(text: 'a.b'));
      expect(result.matches, [0]);
    });

    test('regex search', () {
      final result = filterRecords(
        records,
        const AppLogQuery(text: r'^(net|db)\b', regex: true),
      );
      expect(result.matches, [2, 3]);
    });

    test(
      'an invalid regex is reported, matches nothing, and hides nothing',
      () {
        late AppLogFilterResult result;
        expect(
          () => result = filterRecords(
            records,
            const AppLogQuery(
              text: '(unclosed',
              regex: true,
              onlyMatching: true,
            ),
          ),
          returnsNormally,
        );
        expect(result.patternError, isNotNull);
        expect(result.matches, isEmpty);
        expect(result.lines, hasLength(records.length));
      },
    );

    test(
      'a pattern that matches the empty string does not match every line',
      () {
        final result = filterRecords(
          records,
          const AppLogQuery(text: 'z*', regex: true),
        );
        expect(result.matches, isEmpty);
      },
    );

    test('only matching lines hides the rest', () {
      final result = filterRecords(
        records,
        const AppLogQuery(text: 'o', onlyMatching: true),
      );
      expect(_shown(result), [
        'Hello World',
        'boom',
        'anon',
        'The following StateError',
      ]);
      expect(result.matches, hasLength(4));
    });

    test('channels group errors and are multi-select', () {
      expect(
        _shown(
          filterRecords(
            records,
            const AppLogQuery(channels: {AppLogChannel.errors}),
          ),
        ),
        ['boom', 'The following StateError'],
      );
      expect(
        _shown(
          filterRecords(
            records,
            const AppLogQuery(
              channels: {AppLogChannel.output, AppLogChannel.lifecycle},
            ),
          ),
        ),
        ['Hello World', 'Attached'],
      );
    });

    test('logger names narrow developer logs only', () {
      final result = filterRecords(
        records,
        const AppLogQuery(loggerNames: {'net', ''}),
      );
      expect(_shown(result), [
        'Hello World',
        'boom',
        'net up',
        'anon',
        'Attached',
        'The following StateError',
      ]);
    });

    test('counts are taken before filters', () {
      final result = filterRecords(
        records,
        const AppLogQuery(channels: {AppLogChannel.output}, text: 'nothing'),
      );
      expect(result.countOf(AppLogChannel.output), 1);
      expect(result.countOf(AppLogChannel.errors), 2);
      expect(result.countOf(AppLogChannel.logs), 3);
      expect(result.countOf(AppLogChannel.lifecycle), 1);
      expect(result.loggerCounts, {'net': 1, 'db': 1, '': 1});
      expect(result.newestError?.message, 'The following StateError');
      expect(result.total, records.length);
    });

    test('windows and sequence lookups', () {
      final many = [for (var i = 0; i < 10; i++) _r('line $i')];
      final result = filterRecords(
        many,
        const AppLogQuery(text: 'line [13579]', regex: true),
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
  });

  group('AppLogBuffer sequence numbers', () {
    test('survive dropping and clearing', () {
      final buffer = AppLogBuffer(capacity: 3);
      for (var i = 0; i < 5; i++) {
        buffer.add(_r('line $i'));
      }
      expect(buffer.appended, 5);
      expect(buffer.firstSequence, 2);
      expect(buffer.since(3).map((r) => r.message), ['line 3', 'line 4']);
      expect(buffer.since(0), hasLength(3));
      expect(buffer.since(9), isEmpty);
      buffer.clear();
      expect(buffer.firstSequence, 5);
    });
  });

  group('AppLogFilterCache', () {
    test('an unchanged buffer and query return the same result', () {
      final buffer = AppLogBuffer()..add(_r('a'));
      final cache = AppLogFilterCache();
      final first = cache.update(buffer, const AppLogQuery(text: 'a'));
      expect(cache.update(buffer, const AppLogQuery(text: 'a')), same(first));
      expect(cache.recordsSearched, 1);
    });

    test('a tick searches only what arrived', () {
      final buffer = AppLogBuffer();
      final cache = AppLogFilterCache();
      for (var i = 0; i < 100; i++) {
        buffer.add(_r('line $i'));
      }
      const query = AppLogQuery(text: 'line 9', onlyMatching: true);
      cache.update(buffer, query);
      expect(cache.recordsSearched, 100);
      buffer
        ..add(_r('line 900'))
        ..add(_r('other'));
      final result = cache.update(buffer, query);
      expect(cache.recordsSearched, 102);
      expect(
        result.lines.map((l) => l.record.message),
        filterRecords(buffer.records, query).lines.map((l) => l.record.message),
      );
      expect(result.matches.last, 100);
    });

    test('a new query searches again', () {
      final buffer = AppLogBuffer()
        ..add(_r('a'))
        ..add(_r('b'));
      final cache = AppLogFilterCache();
      cache.update(buffer, const AppLogQuery(text: 'a'));
      final result = cache.update(buffer, const AppLogQuery(text: 'b'));
      expect(cache.recordsSearched, 4);
      expect(result.matches, [1]);
    });

    test('dropped lines leave the result and counts follow', () {
      final buffer = AppLogBuffer(capacity: 3);
      final cache = AppLogFilterCache();
      buffer
        ..add(_r('x1', source: AppLogSource.stderr))
        ..add(_r('x2'))
        ..add(_r('x3'));
      cache.update(buffer, const AppLogQuery(text: 'x'));
      buffer.add(_r('x4'));
      final result = cache.update(buffer, const AppLogQuery(text: 'x'));
      expect(result.lines.map((l) => l.sequence), [1, 2, 3]);
      expect(result.matches, [1, 2, 3]);
      expect(result.countOf(AppLogChannel.errors), 0);
      expect(result.newestError, isNull);
    });

    test('a gap wider than the buffer searches the whole buffer', () {
      final buffer = AppLogBuffer(capacity: 2);
      final cache = AppLogFilterCache();
      buffer.add(_r('a'));
      cache.update(buffer, const AppLogQuery());
      for (var i = 0; i < 5; i++) {
        buffer.add(_r('b$i'));
      }
      final result = cache.update(buffer, const AppLogQuery());
      expect(result.lines.map((l) => l.sequence), [4, 5]);
    });

    test('hideBefore clears the view without touching the buffer', () {
      final buffer = AppLogBuffer()
        ..add(_r('old'))
        ..add(_r('older'));
      final cache = AppLogFilterCache();
      final cleared = cache.update(
        buffer,
        const AppLogQuery(),
        hideBefore: buffer.appended,
      );
      expect(cleared.lines, isEmpty);
      expect(cleared.total, 0);
      buffer.add(_r('new'));
      final result = cache.update(buffer, const AppLogQuery(), hideBefore: 2);
      expect(result.lines.single.record.message, 'new');
      expect(buffer.length, 3);
    });
  });
}
