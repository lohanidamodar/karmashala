import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/timeline/domain/timeline_model.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

void main() {
  final day = DateTime.utc(2026, 10, 6);
  DateTime h(num hours) => day.add(Duration(minutes: (hours * 60).round()));
  var ids = 0;

  ActivityEntry e(
    ActivityKind kind,
    num hours, {
    String session = 's1',
    String project = 'p1',
    String? title,
    String? parent,
    String? detail,
    bool backfilled = false,
    bool approximate = false,
  }) => ActivityEntry(
    id: ++ids,
    at: h(hours),
    kind: kind,
    sessionId: session,
    source: backfilled ? 'transcript' : 'live',
    title: title ?? 'Title $session',
    projectId: project,
    projectName: project == 'p1' ? 'Alpha' : 'Beta',
    parentSessionId: parent,
    detail: detail,
    backfilled: backfilled,
    approximate: approximate,
  );

  TimelineModel build(List<ActivityEntry> entries, {num now = 23}) =>
      buildTimeline(
        entries,
        from: day,
        to: day.add(const Duration(days: 1)),
        now: h(now),
      );

  test('recorded transitions become spans: ready, working, waiting, working, '
      'ready, ended', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9),
      e(ActivityKind.turnStarted, 9.5),
      e(ActivityKind.waitBegan, 10, detail: 'allow write to app/lib'),
      e(ActivityKind.waitEnded, 10.2),
      e(ActivityKind.turnEnded, 11),
      e(ActivityKind.sessionEnded, 12),
    ]);
    final session = model.projects.single.sessions.single;
    expect(session.start, h(9));
    expect(session.end, h(12));
    expect(session.live, isFalse);
    expect(session.spans.map((s) => (s.state, s.from, s.to)), [
      (TimelineState.ready, h(9), h(9.5)),
      (TimelineState.working, h(9.5), h(10)),
      (TimelineState.waiting, h(10), h(10.2)),
      (TimelineState.working, h(10.2), h(11)),
      (TimelineState.ready, h(11), h(12)),
    ]);
    expect(session.ticks, [h(9.5)]);
  });

  test('a wait is measured from when it began to when it was answered, and '
      'says what was asked', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9),
      e(ActivityKind.turnStarted, 9),
      e(ActivityKind.waitBegan, 10, detail: 'allow write to app/lib/main.dart'),
      e(ActivityKind.waitEnded, 10.2),
      e(ActivityKind.waitBegan, 10.5),
      e(ActivityKind.turnEnded, 10.75),
    ]);
    final waits = model.projects.single.sessions.single.spans
        .where((s) => s.state == TimelineState.waiting)
        .toList();
    expect(waits.map((w) => w.duration), [
      const Duration(minutes: 12),
      const Duration(minutes: 15),
    ]);
    expect(
      describeSpan(waits.first),
      'waiting on you 12m (asked to allow write to app/lib/main.dart)',
    );
    expect(model.projects.single.sessions.single.waitingTotal,
        const Duration(minutes: 27));
  });

  test('a live session grows to now; a backfilled one ends at its last entry',
      () {
    final model = build([
      e(ActivityKind.sessionStarted, 9),
      e(ActivityKind.turnStarted, 9.5),
      e(ActivityKind.sessionStarted, 9, session: 'old', backfilled: true),
      e(ActivityKind.turnStarted, 9.5, session: 'old', backfilled: true),
      e(
        ActivityKind.turnEnded,
        10,
        session: 'old',
        backfilled: true,
        approximate: true,
      ),
    ], now: 14);
    final byId = {
      for (final s in model.projects.single.sessions) s.id: s,
    };
    expect(byId['s1']!.live, isTrue);
    expect(byId['s1']!.end, h(14));
    expect(byId['s1']!.spans.last.state, TimelineState.working);
    expect(byId['s1']!.spans.last.to, h(14));
    expect(byId['old']!.live, isFalse);
    expect(byId['old']!.end, h(10));
    expect(byId['old']!.spans.last.approximate, isTrue);
    expect(byId['old']!.backfilled, isTrue);
  });

  test('a session with only a start is a start marker, not a bar', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9, backfilled: true),
    ]);
    final session = model.projects.single.sessions.single;
    expect(session.startOnly, isTrue);
    expect(session.spans, isEmpty);
  });

  test('an answer whose wait was never seen begin is a marker, not a span', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9, backfilled: true),
      e(ActivityKind.turnStarted, 9.5, backfilled: true),
      e(ActivityKind.waitEnded, 9.75, backfilled: true, detail: 'Allow Bash'),
      e(ActivityKind.turnEnded, 10, backfilled: true, approximate: true),
    ]);
    final session = model.projects.single.sessions.single;
    expect(session.spans.where((s) => s.state == TimelineState.waiting), isEmpty);
    expect(session.markers.single.kind, ActivityKind.waitEnded);
    expect(session.markers.single.at, h(9.75));
  });

  test('a deleted session still draws, with the title it was logged with', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9, title: 'First name'),
      e(ActivityKind.renamed, 9.1, title: 'Second name', detail: 'Second name'),
      e(ActivityKind.turnStarted, 9.5, title: 'Second name'),
      e(ActivityKind.turnEnded, 10, title: 'Second name'),
      e(ActivityKind.deleted, 11, title: 'Second name'),
    ]);
    final session = model.projects.single.sessions.single;
    expect(session.title, 'Second name');
    expect(session.end, h(11));
    expect(session.deleted, isTrue);
  });

  test('arrows connect a parent to the child it started, and children are '
      'grouped under their parent', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9, session: 'parent'),
      e(ActivityKind.sessionStarted, 9.5, session: 'other'),
      e(ActivityKind.sessionStarted, 10, session: 'child', parent: 'parent'),
      e(ActivityKind.linked, 10, session: 'child', parent: 'parent'),
      // A link to a session nowhere in view draws no arrow.
      e(ActivityKind.sessionStarted, 10, session: 'orphan', parent: 'gone'),
      e(ActivityKind.linked, 10, session: 'orphan', parent: 'gone'),
    ]);
    expect(model.arrows.map((a) => (a.parentId, a.childId, a.at)), [
      ('parent', 'child', h(10)),
    ]);
    final order = model.projects.single.sessions.map((s) => s.id).toList();
    expect(order, ['parent', 'child', 'other', 'orphan']);
    final child = model.projects.single.sessions[1];
    expect(child.depth, 1);
    expect(child.parentId, 'parent');
  });

  test('a session that started before the range opens at the range', () {
    final model = build([
      ActivityEntry(
        id: 1,
        at: h(-3),
        kind: ActivityKind.sessionStarted,
        sessionId: 's1',
        source: 'live',
        projectId: 'p1',
      ),
      ActivityEntry(
        id: 2,
        at: h(-1),
        kind: ActivityKind.turnStarted,
        sessionId: 's1',
        source: 'live',
        projectId: 'p1',
      ),
      e(ActivityKind.turnEnded, 2),
    ]);
    final session = model.projects.single.sessions.single;
    expect(session.start, h(-3));
    expect(session.spans.first.state, TimelineState.working);
    expect(session.spans.first.to, h(2));
  });

  test('projects are rows, by name, each with its own sessions', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9, project: 'p2', session: 'b'),
      e(ActivityKind.sessionStarted, 9, project: 'p1', session: 'a'),
    ]);
    expect(model.projects.map((p) => p.name), ['Alpha', 'Beta']);
    expect(model.projects.first.sessions.single.id, 'a');
  });

  test('a usage limit pauses until it resumes', () {
    final model = build([
      e(ActivityKind.sessionStarted, 9),
      e(ActivityKind.turnStarted, 9),
      e(ActivityKind.turnEnded, 9.5, detail: 'failed: rate_limit'),
      e(ActivityKind.limitPaused, 9.5, detail: 'resets at 11:00'),
      e(ActivityKind.limitResumed, 11),
      e(ActivityKind.turnStarted, 11),
      e(ActivityKind.turnEnded, 12),
      e(ActivityKind.sessionEnded, 12),
    ]);
    final spans = model.projects.single.sessions.single.spans;
    expect(
      spans.map((s) => s.state),
      contains(TimelineState.paused),
    );
    final paused = spans.singleWhere((s) => s.state == TimelineState.paused);
    expect((paused.from, paused.to), (h(9.5), h(11)));
  });

  test('a 150-session day of thousands of turns builds quickly', () {
    final entries = <ActivityEntry>[];
    for (var s = 0; s < 150; s++) {
      final session = 's$s';
      entries.add(
        e(ActivityKind.sessionStarted, (s % 20) * 0.5, session: session,
            project: s.isEven ? 'p1' : 'p2',
            parent: s > 10 && s % 7 == 0 ? 's${s - 7}' : null),
      );
      for (var t = 0; t < 20; t++) {
        final at = (s % 20) * 0.5 + t * 0.15;
        entries
          ..add(e(ActivityKind.turnStarted, at, session: session,
              project: s.isEven ? 'p1' : 'p2'))
          ..add(e(ActivityKind.turnEnded, at + 0.1, session: session,
              project: s.isEven ? 'p1' : 'p2'));
      }
    }
    final watch = Stopwatch()..start();
    final model = build(entries);
    watch.stop();
    expect(model.sessionCount, 150);
    expect(watch.elapsedMilliseconds, lessThan(200));
  });
}
