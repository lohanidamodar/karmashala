import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/activity/activity_backfill.dart';
import 'package:karmashala_host/src/activity/activity_log.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'activity_fixture.dart';

/// The backfill: what existed before the log, recovered once, correctly.
void main() {
  late AppDatabase db;
  late ActivityLog log;
  late Map<String, List<TranscriptMessage>> transcripts;
  late List<String> read;
  final day = DateTime.utc(2026, 9, 20);
  DateTime h(num hours) => day.add(Duration(minutes: (hours * 60).round()));

  /// A store as it stood before v80: rows, and no log of them.
  void seed() {
    insertSession(db, 's1', at: h(9), status: 'completed');
    insertSession(db, 'child', at: h(10), parent: 's1');
    insertSession(db, 'cp', at: h(12), archivedAt: h(18));
    insertSession(db, 'quiet', at: h(13));
    insertImported(db, 'i1', repository: 'r2', at: h(20));
    db.execute(
      'INSERT INTO session_delegations (child_session_id, parent_session_id, '
      "title, agent, delegated_at, turn) VALUES ('child', 's1', 'T', 'x', ?, "
      '1);',
      [h(10.5).toIso8601String()],
    );
    for (final (id, reason, at) in [
      ('c1', 'turnStart', h(12.5)),
      ('c2', 'turn', h(12.75)),
      ('c3', 'manual', h(13)),
    ]) {
      db.execute(
        'INSERT INTO session_checkpoints (id, session_id, environment_id, '
        'repository_path, sequence, tree_sha, commit_sha, reason, '
        "created_at) VALUES (?, 'cp', 'e1', '/a', 1, 't', 'c', ?, ?);",
        [id, reason, at.toIso8601String()],
      );
    }
    db.execute(
      'INSERT INTO session_decisions (session_id, sequence, kind, summary, '
      "origin_kind, recorded_at) VALUES ('s1', 1, 'approvalGranted', "
      "'Allow Bash: npm test', 'approvalPrompt', ?);",
      [h(9.4).toIso8601String()],
    );
    db.execute(
      'INSERT INTO scheduled_resumes (id, session_id, fire_at, state, '
      "scheduled_at, finished_at, window_label) VALUES ('r1', 's1', ?, "
      "'done', ?, ?, '5-hour');",
      [h(11).toIso8601String(), h(10).toIso8601String(), h(11).toIso8601String()],
    );
    // What a log written live would not have: the store as of before v80.
    db.execute('DELETE FROM activity_log;');
    transcripts = {
      's1': [
        TranscriptMessage(role: 'user', text: 'go', at: h(9.1)),
        TranscriptMessage(role: 'agent', text: 'ok', at: h(9.2)),
        TranscriptMessage(role: 'tool', text: 'Bash', at: h(9.5)),
        TranscriptMessage(role: 'user', text: 'more', at: h(10)),
        TranscriptMessage(role: 'user', text: 'and this', at: h(10.01)),
        TranscriptMessage(role: 'agent', text: 'done', at: h(10.25)),
        // A line with no time of its own is never given one.
        const TranscriptMessage(role: 'user', text: 'undated'),
      ],
      'i1': [
        TranscriptMessage(role: 'user', text: 'hi', at: h(20.5)),
        TranscriptMessage(role: 'agent', text: 'hello', at: h(20.6)),
      ],
    };
  }

  setUp(() {
    db = activityStore();
    log = ActivityLog(db, clock: () => h(30));
    read = [];
    seed();
  });
  tearDown(() => db.close());

  ActivityBackfill backfill({int chunk = 50}) => ActivityBackfill(
    db,
    log: log,
    messagesOf: (id) async {
      read.add(id);
      return transcripts[id] ?? const [];
    },
    chunk: chunk,
    pause: Duration.zero,
  );

  List<ActivityEntry> of(String sessionId) => [
    for (final e in log.after(0))
      if (e.sessionId == sessionId) e,
  ]..sort((a, b) => a.at.compareTo(b.at));

  test('session rows: their start, archive and parent link', () async {
    await backfill().run();
    expect(of('cp').where((e) => e.source == 'session').map((e) => (e.kind, e.at)), [
      (ActivityKind.sessionStarted, h(12)),
      (ActivityKind.archived, h(18)),
    ]);
    final link = of('child').singleWhere((e) => e.kind == ActivityKind.linked);
    expect(link.parentSessionId, 's1');
    expect(link.backfilled, isTrue);
    expect(link.approximate, isFalse);
    expect(of('s1').first.title, 'Title s1');
    expect(of('s1').first.projectName, 'Alpha');
  });

  test('transcripts: each turn starts at its prompt and ends, approximately, '
      'at its last reply', () async {
    await backfill().run();
    final turns = of('s1').where((e) => e.source == 'transcript');
    expect(turns.map((e) => (e.kind, e.at, e.approximate)), [
      (ActivityKind.turnStarted, h(9.1), false),
      (ActivityKind.turnEnded, h(9.5), true),
      (ActivityKind.turnStarted, h(10), false),
      (ActivityKind.turnEnded, h(10.25), true),
    ]);
    expect(turns.every((e) => e.backfilled), isTrue);
  });

  test('an imported session starts, approximately, at its first message, in '
      'its own project', () async {
    await backfill().run();
    final entries = of('i1');
    expect(entries.first.kind, ActivityKind.sessionStarted);
    expect(entries.first.at, h(20.5));
    expect(entries.first.approximate, isTrue);
    expect(entries.first.projectName, 'Beta');
    expect(entries.map((e) => e.kind), contains(ActivityKind.turnEnded));
  });

  test('checkpoints give turns only to a session no transcript did', () async {
    await backfill().run();
    expect(
      of('cp').where((e) => e.source == 'checkpoint').map((e) => (e.kind, e.at)),
      [(ActivityKind.turnStarted, h(12.5)), (ActivityKind.turnEnded, h(12.75))],
    );
    expect(of('s1').where((e) => e.source == 'checkpoint'), isEmpty);
  });

  test('answered approvals end a wait whose start is not recorded', () async {
    await backfill().run();
    final wait = of('s1').singleWhere((e) => e.source == 'decision');
    expect(wait.kind, ActivityKind.waitEnded);
    expect(wait.at, h(9.4));
    expect(wait.detail, 'Allow Bash: npm test');
    expect(of('s1').where((e) => e.kind == ActivityKind.waitBegan), isEmpty);
  });

  test('a scheduled resume pauses, approximately, and resumes', () async {
    await backfill().run();
    expect(
      of('s1').where((e) => e.source == 'resume').map(
        (e) => (e.kind, e.at, e.approximate),
      ),
      [
        (ActivityKind.limitPaused, h(10), true),
        (ActivityKind.limitResumed, h(11), false),
      ],
    );
  });

  test('a finished session ends, approximately, at its last known activity; '
      'one with only a start stays a start', () async {
    await backfill().run();
    final end = of('s1').singleWhere((e) => e.kind == ActivityKind.sessionEnded);
    expect(end.at, h(11));
    expect(end.approximate, isTrue);
    expect(end.detail, 'completed');
    expect(of('quiet').map((e) => e.kind), [ActivityKind.sessionStarted]);
  });

  test('running it again adds nothing', () async {
    await backfill().run();
    final first = log.after(0).length;
    db.execute("DELETE FROM app_metadata WHERE key = '$kActivityBackfillKey';");
    await backfill().run();
    expect(log.after(0), hasLength(first));
  });

  test('once done it is recorded and not run again', () async {
    final first = backfill();
    await first.run();
    expect(first.isDone, isTrue);
    read.clear();
    await backfill().run();
    expect(read, isEmpty);
  });

  test('stopped mid-way, a restart resumes where it was and ends with the same '
      'log', () async {
    final whole = activityStore();
    // The uninterrupted run, on its own copy of the store.
    final reference = () async {
      final saved = db;
      db = whole;
      seed();
      db = saved;
      await ActivityBackfill(
        whole,
        log: ActivityLog(whole, clock: () => h(30)),
        messagesOf: (id) async => transcripts[id] ?? const [],
        pause: Duration.zero,
      ).run();
      return ActivityLog(whole).after(0).map((e) => (e.sessionId, e.kind, e.at)).toSet();
    }();


    final interrupted = backfill(chunk: 1);
    await interrupted.run(shouldStop: () => read.contains('s1'));
    expect(interrupted.isDone, isFalse);
    final partial = log.after(0).length;
    expect(partial, greaterThan(0));

    read.clear();
    await backfill(chunk: 1).run();
    expect(read, isNot(contains('s1')), reason: 'done before the stop');
    final resumed = log.after(0).map((e) => (e.sessionId, e.kind, e.at)).toSet();
    expect(resumed, await reference);
    expect(log.after(0).length, resumed.length, reason: 'nothing twice');
    whole.close();
  });

  test('a session deleted before the log existed draws nothing', () async {
    db.execute("DELETE FROM sessions WHERE id = 'quiet';");
    db.execute(
      "DELETE FROM activity_log WHERE session_id = 'quiet';",
    );
    await backfill().run();
    expect(of('quiet'), isEmpty);
  });

  test('a transcript that cannot be read costs that session, not the run',
      () async {
    await ActivityBackfill(
      db,
      log: log,
      messagesOf: (id) async =>
          id == 's1' ? throw StateError('gone') : transcripts[id] ?? const [],
      pause: Duration.zero,
    ).run();
    expect(of('i1').where((e) => e.source == 'transcript'), isNotEmpty);
    expect(of('s1').where((e) => e.source == 'transcript'), isEmpty);
  });
}
