import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:agent_cli/src/cli_detection/data/agent_lifetime_reader.dart';
import 'package:agent_cli/src/cli_detection/domain/session_stats.dart';
import 'package:path/path.dart' as p;
import '../support/fake_sqlite.dart';

/// The agents' own lifetime books, read rather than reconstructed.
///
/// Both fixtures are the real shapes, copied off a live store: Claude Code's
/// `stats-cache.json` at `version: 2`, and Codex's `threads` table out of
/// `state_5.sqlite`. The point of every test here is that this app reports what
/// the CLI wrote down and never adds sessions together to invent a total.
void main() {
  late Directory tmp;
  late FakeSqliteFiles sqlite;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_lifetime_');
    sqlite = FakeSqliteFiles();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open.
    }
  });

  group('Claude Code, from the cache its stats screen keeps', () {
    late String home;

    setUp(() {
      home = p.join(tmp.path, '.claude');
      Directory(home).createSync(recursive: true);
    });

    void writeCache(Map<String, Object?> json) => File(
      p.join(home, 'stats-cache.json'),
    ).writeAsStringSync(jsonEncode(json));

    /// The owner's own file, field for field.
    Map<String, Object?> real() => {
      'version': 2,
      'lastComputedDate': '2026-02-24',
      'dailyActivity': [
        {
          'date': '2026-02-01',
          'messageCount': 1297,
          'sessionCount': 1,
          'toolCallCount': 226,
        },
      ],
      'dailyModelTokens': [
        {
          'date': '2026-02-01',
          'tokensByModel': {'claude-sonnet-4-5-20250929': 6531},
        },
      ],
      'modelUsage': {
        'claude-sonnet-4-5-20250929': {
          'inputTokens': 5332,
          'outputTokens': 1199,
          'cacheReadInputTokens': 44952107,
          'cacheCreationInputTokens': 1384461,
          'webSearchRequests': 0,
          'costUSD': 12.5,
          'contextWindow': 0,
          'maxOutputTokens': 0,
        },
      },
      'totalSessions': 1,
      'totalMessages': 1297,
      'longestSession': {
        'sessionId': '81950938-6c19-408a-ba9c-bd72f1c952d1',
        'duration': 9270545,
        'messageCount': 1297,
        'timestamp': '2026-02-01T09:41:48.537Z',
      },
      'firstSessionDate': '2026-02-01T09:41:48.537Z',
      'hourCounts': {'15': 1},
      'totalSpeculationTimeSavedMs': 0,
    };

    test('it reads the totals, the models and the date they were computed', () async {
      writeCache(real());

      final stats = await ClaudeLifetimeReader(
        cache: ClaudeLifetimeCache(),
      ).read(home);

      expect(stats, isNotNull);
      expect(stats!.source, LifetimeStatsSource.agentCache);
      expect(stats.sessions, 1);
      expect(stats.messages, 1297);
      expect(stats.tokens.input, 5332);
      expect(stats.tokens.output, 1199);
      expect(stats.tokens.cacheRead, 44952107);
      expect(stats.tokens.cacheCreated, 1384461);
      expect(stats.totalTokens, 5332 + 1199 + 44952107 + 1384461);
      // The calendar day the CLI stamped, in the timezone it stamped it —
      // pushed to UTC it would read as the 23rd here and the dialog would call
      // the cache a day staler than it is.
      expect(stats.computedAt, DateTime(2026, 2, 24));
      expect(stats.firstActivityAt, DateTime.utc(2026, 2, 1, 9, 41, 48, 537));
    });

    test('the cache carries a cost and it is deliberately not read', () async {
      writeCache(real());

      final stats = (await ClaudeLifetimeReader(
        cache: ClaudeLifetimeCache(),
      ).read(home))!;

      // `costUSD: 12.5` is right there in the fixture. Nothing in LifetimeStats
      // can hold it, which is the point.
      expect(stats.note, isNot(contains(r'$')));
      expect(stats.note, contains('messages'));
    });

    test('several models are added together', () async {
      writeCache({
        ...real(),
        'modelUsage': {
          'a': {'inputTokens': 10, 'outputTokens': 1},
          'b': {'inputTokens': 5, 'outputTokens': 2, 'cacheReadInputTokens': 7},
        },
      });

      final stats = (await ClaudeLifetimeReader(
        cache: ClaudeLifetimeCache(),
      ).read(home))!;

      expect(stats.tokens.input, 15);
      expect(stats.tokens.output, 3);
      expect(stats.tokens.cacheRead, 7);
      expect(stats.totalTokens, 25);
    });

    test('a cache with no model usage reports no tokens, not zero', () async {
      writeCache({'version': 2, 'totalSessions': 4, 'totalMessages': 9});

      final stats = (await ClaudeLifetimeReader(
        cache: ClaudeLifetimeCache(),
      ).read(home))!;

      expect(stats.sessions, 4);
      expect(stats.tokens.isUnknown, isTrue);
      expect(stats.totalTokens, isNull);
    });

    test('a stale cache still says when it was written', () async {
      // The real one on this machine: computed in February, read in September,
      // claiming a single session while the store beside it holds 38 files.
      writeCache(real());

      final stats = (await ClaudeLifetimeReader(
        cache: ClaudeLifetimeCache(),
      ).read(home))!;

      expect(stats.computedAt, isNotNull);
      expect(
        stats.computedAt!.isBefore(DateTime(2026, 3)),
        isTrue,
        reason: 'the dialog needs this to say how old the number is',
      );
    });

    test('a missing cache is absent, not empty', () async {
      expect(
        await ClaudeLifetimeReader(cache: ClaudeLifetimeCache()).read(home),
        isNull,
      );
    });

    test('a half-written cache is refused rather than half-read', () async {
      File(p.join(home, 'stats-cache.json')).writeAsStringSync('{"version": 2,');
      expect(
        await ClaudeLifetimeReader(cache: ClaudeLifetimeCache()).read(home),
        isNull,
      );
    });

    test('reading it twice reads it once', () async {
      writeCache(real());
      final reader = ClaudeLifetimeReader(cache: ClaudeLifetimeCache());

      await reader.read(home);
      expect(reader.bytesRead, greaterThan(0));
      final afterFirst = reader.bytesRead;

      await reader.read(home);

      expect(reader.bytesRead - afterFirst, 0);
    });

    test('and a rewritten cache is read again', () async {
      writeCache(real());
      final reader = ClaudeLifetimeReader(cache: ClaudeLifetimeCache());
      expect((await reader.read(home))!.messages, 1297);

      writeCache({...real(), 'totalMessages': 2000});

      expect((await reader.read(home))!.messages, 2000);
    });
  });

  group('Codex, from the thread index it keeps as it runs', () {
    late String home;

    setUp(() {
      home = p.join(tmp.path, '.codex');
      Directory(home).createSync(recursive: true);
    });

    /// `state_<version>.sqlite` with the columns the real one has that matter,
    /// as rows rather than as a database — see [FakeSqliteFiles].
    void writeIndex(
      int version,
      List<(String id, int tokens, int createdAt, int updatedAt)> threads,
    ) {
      sqlite.put(p.join(home, 'state_$version.sqlite'), 'threads', [
        for (final (id, tokens, created, updated) in threads)
          {
            'id': id,
            'created_at': created,
            'updated_at': updated,
            'tokens_used': tokens,
          },
      ]);
    }

    test('it counts threads and dates them, and shows no token total', () async {
      writeIndex(5, [
        ('a', 41611532, 1785922680, 1785929836),
        ('b', 114878384, 1772850774, 1773068557),
        ('c', 1033423, 1786000000, 1786000900),
      ]);

      final stats = await CodexLifetimeReader(readRows: sqlite.read).read(home);

      expect(stats, isNotNull);
      expect(stats!.source, LifetimeStatsSource.agentIndex);
      expect(stats.sessions, 3);
      expect(
        stats.firstActivityAt,
        DateTime.fromMillisecondsSinceEpoch(1772850774 * 1000, isUtc: true),
      );
      expect(
        stats.lastActivityAt,
        DateTime.fromMillisecondsSinceEpoch(1786000900 * 1000, isUtc: true),
      );
      // The column is right there and adds to 157,523,339. It is not summed:
      // a subagent thread can replay its parent's usage into its own rollout,
      // and this index is derived from those. Counting rows cannot be inflated
      // that way; adding this column can.
      expect(stats.totalTokens, isNull);
      expect(stats.tokens.isUnknown, isTrue);
      expect(stats.note, contains('replay'));
    });

    test('the newest schema version wins', () async {
      writeIndex(4, [('old', 1, 1, 2)]);
      writeIndex(11, [('new', 1, 1, 2), ('new2', 1, 1, 2)]);

      final stats = await CodexLifetimeReader(readRows: sqlite.read).read(home);

      expect(
        stats!.sessions,
        2,
        reason: 'state_11 is newer than state_4, not alphabetically earlier',
      );
    });

    test('a store with no index at all is absent', () async {
      expect(await CodexLifetimeReader(readRows: sqlite.read).read(home), isNull);
    });

    test('a home that does not exist is absent', () async {
      expect(
        await CodexLifetimeReader(readRows: sqlite.read).read(p.join(tmp.path, 'nope')),
        isNull,
      );
    });

    test('an index whose schema moved on is absent, never a zero', () async {
      sqlite.put(p.join(home, 'state_9.sqlite'), 'conversations', const []);

      final stats = await CodexLifetimeReader(readRows: sqlite.read).read(home);

      expect(stats, isNull, reason: 'no threads table is not "no threads"');
    });

    test('an empty index reports no threads rather than nothing', () async {
      writeIndex(5, const []);

      final stats = await CodexLifetimeReader(readRows: sqlite.read).read(home);

      expect(stats!.sessions, 0);
      expect(stats.firstActivityAt, isNull);
    });
  });
}
