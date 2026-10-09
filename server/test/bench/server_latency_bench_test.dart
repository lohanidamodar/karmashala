@Tags(['cost'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/activity/activity_backfill.dart';
import 'package:karmashala_host/src/data/conversations_handler.dart';
import 'package:karmashala_host/src/sessions/session_transcripts.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// **The server under backfill, timed from a client's side** — what a phone
/// waits for `sessions.list`, a transcript page, a send and a status poll
/// while the conversation index and the activity log catch up with a large
/// store, and the longest the event loop went without turning.
///
/// Opt-in: `KARMASHALA_LATENCY_BENCH=1`. Synthetic data in a temp folder,
/// never a real data dir. The thresholds are a generous regression guard;
/// the printed numbers are the reading.
void main() {
  final enabled = Platform.environment['KARMASHALA_LATENCY_BENCH'] == '1';

  test(
    'client requests stay responsive during backfill',
    () async {
      final dir = Directory.systemTemp.createTempSync('server_latency_bench_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // A handle Windows has not let go of yet; the temp dir is swept.
        }
      });
      final fixture = await _Fixture.build(dir);
      addTearDown(fixture.close);

      final idle = await _measure(fixture, const Duration(seconds: 3));

      final backfills = Stopwatch()..start();
      final load = _Load(fixture)..start();
      Future<String> timed(String name, Future<Object> Function() run) async {
        final w = Stopwatch()..start();
        try {
          final result = await run();
          return '$name: $result in ${w.elapsedMilliseconds} ms';
        } on Object catch (error) {
          // As serve does: the backfill stops, the server goes on.
          final words = '$error';
          return '$name STOPPED after ${w.elapsedMilliseconds} ms: '
              '${words.length > 120 ? words.substring(0, 120) : words}';
        }
      }

      // As serve runs them, one after the other. `KARMASHALA_LATENCY_ONLY=
      // conversations|activity` runs one alone, `=together` both at once.
      final only = Platform.environment['KARMASHALA_LATENCY_ONLY'];
      Future<String> index() => timed(
        'conversation index',
        () => fixture.service.conversations.backfill(),
      );
      Future<String> log() => timed('activity log', fixture.activityBackfill);
      final outcomes = switch (only) {
        'conversations' => [await index()],
        'activity' => [await log()],
        'together' => await Future.wait([index(), log()]),
        _ => [await index(), await log()],
      };
      backfills.stop();
      final busy = await load.stopAndDrain();
      final indexed = fixture.service.conversations.dao.counts().conversations;

      // ignore: avoid_print
      print(
        [
          'SERVER LATENCY BENCH',
          'fixture: ${fixture.describe()}',
          'idle (3 s):',
          ...idle.lines(),
          'during backfill (${backfills.elapsedMilliseconds} ms):',
          for (final outcome in outcomes) '  $outcome',
          ...busy.lines(),
        ].join('\n'),
      );

      if (only != 'activity') expect(indexed, greaterThan(0));
      expect(outcomes.where((o) => o.contains('STOPPED')), isEmpty);
      // Before round 77: p95 1.4 s, a 2 s stall. After: about 45 ms and
      // 100 ms. Generous, so a busy machine does not fail it.
      expect(busy.all.p95, lessThan(300));
      expect(busy.maxStallMs, lessThan(600));
    },
    skip: enabled ? false : 'set KARMASHALA_LATENCY_BENCH=1 to run',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

const _sessions = 200;
const _bigEventSessions = 3;
const _eventsPerBig = 20000;
const _hugeMegabytes = 50;
const _firstWatched = 10;
const _watched = 3;

class _Fixture {
  _Fixture._(this.db, this.service, this.app, this.transcripts, this.bytes);

  final AppDatabase db;
  final DataService service;
  final DataSession app;
  final SessionTranscripts transcripts;
  final int bytes;
  var _sent = 0;

  static Future<_Fixture> build(Directory dir) async {
    final now = DateTime.utc(2026, 10, 9, 12);
    final here = localHostEnvironment(now);
    final home = Directory(p.join(dir.path, 'home'))..createSync();
    final store = Directory(p.join(home.path, '.claude', 'projects', '-src-r1'))
      ..createSync(recursive: true);

    final corpus = _Corpus(Random(77));
    final paths = <String, String>{};
    var bytes = 0;
    for (var i = 0; i < _sessions; i++) {
      final path = p.join(store.path, 'c$i.jsonl');
      final sink = File(path).openWrite();
      final target = i == 0
          ? _hugeMegabytes * 1024 * 1024
          : i <= _bigEventSessions
          ? 12 * 1024 * 1024
          : 40 * 1024 + corpus.random.nextInt(300 * 1024);
      var written = 0;
      while (written < target) {
        final e = corpus.exchange();
        sink.write(e);
        written += e.length;
      }
      await sink.close();
      bytes += written;
      paths['s$i'] = path;
    }

    final db = AppDatabase.open(
      Directory(p.join(dir.path, 'db'))..createSync(),
    );
    const at = '2026-01-01T00:00:00.000Z';
    ExecutionEnvironmentDao(db).upsert(here);
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Demo', ?, '/src/r1', ?);",
      [here.id, at],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'r1', ?, '/src/r1', ?);",
      [here.id, at],
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('a1', 'claudeCode', ?, "
      "'claude', ?);",
      [here.id, at],
    );

    final service = DataService(db);
    final app = service.open((_) {});
    for (var i = 0; i < _sessions; i++) {
      app.handle(
        SessionCreate(
          Session(
            id: 's$i',
            repositoryId: 'r1',
            agentInstallationId: 'a1',
            title: 'Session $i',
            useWorktree: false,
            status: SessionStatus.completed,
            createdAt: now.subtract(Duration(minutes: i)),
            externalSessionId: 'c$i',
          ),
        ),
      );
    }
    db.transaction(() {
      for (var s = 1; s <= _bigEventSessions; s++) {
        for (var seq = 0; seq < _eventsPerBig; seq++) {
          db.execute(
            'INSERT INTO session_events '
            '(session_id, seq, type, payload, created_at) '
            'VALUES (?, ?, ?, ?, ?);',
            [
              's$s',
              seq,
              'message.agent',
              jsonEncode({'text': corpus.sentence(30)}),
              at,
            ],
          );
        }
      }
    });

    final transcripts = SessionTranscripts(
      lookUp: (id) async =>
          (path: paths[id], agentId: AgentIds.claudeCode, absence: null),
    );
    service.sessionTranscripts = transcripts;
    service.conversations.start(
      TranscriptStores(
        locator: CliStoreLocator(
          runnerFor: (_) => const LocalCommandRunner(),
          environment: {'HOME': home.path, 'USERPROFILE': home.path},
        ),
        environments: () => [here],
      ),
    );
    // A phone watches the transcripts it reads: held, polled, never evicted.
    for (var i = 0; i < _watched; i++) {
      await app.handleJson({
        'id': -1 - i,
        'kind': SessionTranscriptWatch.name,
        'arguments': {'sessionId': 's${_firstWatched + i}'},
      });
    }
    return _Fixture._(db, service, app, transcripts, bytes);
  }

  Future<int> activityBackfill() => ActivityBackfill(
    db,
    log: service.activity,
    messagesOf: transcripts.messagesOf,
  ).run();

  String describe() =>
      '$_sessions sessions, ${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB '
      'of transcripts (one $_hugeMegabytes MB), $_bigEventSessions sessions '
      'of $_eventsPerBig events';

  /// One of the four, in turn, through the JSON envelope a client uses.
  Future<void> request(int n) async {
    final Map<String, Object?> json = switch (n % 4) {
      0 => {'id': n, 'kind': SessionsList.name, 'arguments': const {}},
      1 => {
        'id': n,
        'kind': SessionTranscriptRead.name,
        'arguments': {
          'sessionId': 's${_firstWatched + n % _watched}',
          'limit': 50,
        },
      },
      2 => {
        'id': n,
        'kind': SessionEventsAppend.name,
        'arguments': {
          'events': [
            SessionEvent(
              sessionId: 's5',
              seq: 0,
              type: 'message.user',
              payload: jsonEncode({'text': 'send ${_sent++}'}),
              createdAt: DateTime.now().toUtc(),
            ).toJson(),
          ],
        },
      },
      _ => {'id': n, 'kind': ConversationsStatus.name, 'arguments': const {}},
    };
    final answer = await app.handleJson(json);
    if (answer.containsKey('refusal') || answer.containsKey('error')) {
      throw StateError('${json['kind']} refused: $answer');
    }
    jsonEncode(answer);
  }

  Future<void> close() async {
    service.conversations.close();
    db.close();
  }
}

const _kinds = [
  'sessions.list',
  'sessions.transcript',
  'send (appendEvents)',
  'conversations.status',
];

class _Readings {
  final Map<String, List<double>> byKind = {for (final k in _kinds) k: []};
  final List<double> stalls = [];

  _Stats get all => _Stats([for (final l in byKind.values) ...l]);
  double get maxStallMs => stalls.isEmpty ? 0 : stalls.reduce(max);

  Iterable<String> lines() sync* {
    for (final entry in byKind.entries) {
      yield '  ${entry.key.padRight(22)} ${_Stats(entry.value)}';
    }
    yield '  ${'all'.padRight(22)} $all';
    final sorted = [...stalls]..sort();
    yield '  event-loop stall: max ${maxStallMs.toStringAsFixed(0)} ms, '
        'over 100 ms ${stalls.where((s) => s > 100).length}, '
        'over 250 ms ${stalls.where((s) => s > 250).length}, '
        'worst five ${sorted.reversed.take(5).map((s) => s.toStringAsFixed(0)).join(', ')}';
  }
}

class _Stats {
  _Stats(List<double> samples) : sorted = [...samples]..sort();

  final List<double> sorted;

  double at(double q) => sorted.isEmpty
      ? 0
      : sorted[((sorted.length - 1) * q).round().clamp(0, sorted.length - 1)];
  double get p95 => at(.95);

  @override
  String toString() =>
      'p50 ${at(.5).toStringAsFixed(1)} ms  p95 ${p95.toStringAsFixed(1)} ms  '
      'max ${(sorted.isEmpty ? 0 : sorted.last).toStringAsFixed(1)} ms  '
      '(n=${sorted.length})';
}

/// A client asking every [period], timed from when it meant to ask — so a
/// held event loop counts against the request — and a ticker whose lateness
/// is the stall.
class _Load {
  _Load(this.fixture);

  final _Fixture fixture;
  static const period = Duration(milliseconds: 25);
  static const beat = Duration(milliseconds: 5);
  final _readings = _Readings();
  final _clock = Stopwatch();
  final _pending = <Future<void>>[];
  Timer? _asking;
  Timer? _ticking;

  void start() {
    _clock.start();
    _ticking = Timer.periodic(beat, (_) {
      final now = _clock.elapsedMicroseconds;
      _readings.stalls.add((now - _lastBeat - beat.inMicroseconds) / 1000);
      _lastBeat = now;
    });
    _asking = Timer.periodic(period, (timer) {
      // A held loop skips ticks; the clients it kept waiting still asked.
      for (var n = _asked + 1; n <= timer.tick; n++) {
        _ask(n);
      }
      _asked = timer.tick;
    });
  }

  /// Stops asking and waits for what is in flight. Whatever held the loop
  /// last ends in a microtask, before any timer runs: its gap and the
  /// requests it held are taken here, or they would be lost.
  Future<_Readings> stopAndDrain() async {
    _asking?.cancel();
    _ticking?.cancel();
    final now = _clock.elapsedMicroseconds;
    _readings.stalls.add((now - _lastBeat - beat.inMicroseconds) / 1000);
    for (var n = _asked + 1; n <= now ~/ period.inMicroseconds; n++) {
      _ask(n);
    }
    await Future.wait(_pending);
    return _readings;
  }

  var _lastBeat = 0;
  var _asked = 0;

  void _ask(int n) {
    final meant = n * period.inMicroseconds;
    _pending.add(
      fixture.request(n).then((_) {
        _readings.byKind[_kinds[n % 4]]!.add(
          (_clock.elapsedMicroseconds - meant) / 1000,
        );
      }),
    );
  }
}

Future<_Readings> _measure(_Fixture fixture, Duration span) async {
  final load = _Load(fixture)..start();
  await Future<void>.delayed(span);
  return load.stopAndDrain();
}

/// Claude Code's JSONL shape, with most bytes in tool output as real
/// transcripts have.
class _Corpus {
  _Corpus(this.random);

  final Random random;
  var _call = 0;

  String word() {
    final length = 2 + random.nextInt(9);
    return String.fromCharCodes([
      for (var i = 0; i < length; i++) 97 + random.nextInt(26),
    ]);
  }

  String sentence(int words) =>
      [for (var i = 0; i < words; i++) word()].join(' ');

  String exchange() {
    final out = StringBuffer()
      ..writeln(
        jsonEncode({
          'type': 'user',
          'timestamp': '2026-10-09T10:00:00.000Z',
          'message': {
            'role': 'user',
            'content': sentence(10 + random.nextInt(30)),
          },
        }),
      );
    for (var c = random.nextInt(4); c > 0; c--) {
      final id = 'toolu_${_call++}';
      out
        ..writeln(
          jsonEncode({
            'type': 'assistant',
            'timestamp': '2026-10-09T10:00:01.000Z',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'id': id,
                  'name': 'Bash',
                  'input': {'command': 'grep -rn ${word()} lib'},
                },
              ],
            },
          }),
        )
        ..writeln(
          jsonEncode({
            'type': 'user',
            'timestamp': '2026-10-09T10:00:02.000Z',
            'message': {
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'content': sentence(40 + random.nextInt(600)),
                },
              ],
            },
          }),
        );
    }
    out.writeln(
      jsonEncode({
        'type': 'assistant',
        'timestamp': '2026-10-09T10:00:05.000Z',
        'message': {
          'content': [
            {'type': 'text', 'text': sentence(20 + random.nextInt(100))},
          ],
        },
      }),
    );
    return out.toString();
  }
}
