import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/activity/activity_log.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'activity_fixture.dart';

void main() {
  late AppDatabase db;
  late ActivityLog log;
  final day = DateTime.utc(2026, 10, 6);
  DateTime h(num hours) =>
      day.add(Duration(minutes: (hours * 60).round()));

  setUp(() {
    db = activityStore();
    log = ActivityLog(db, clock: () => h(23));
  });
  tearDown(() => db.close());

  ActivityPage rangeOf({
    DateTime? from,
    DateTime? to,
    List<String>? projects,
    ActivityCursor? after,
    int limit = kActivityPageLimit,
  }) => log.range(
    ActivityRange(
      from: from ?? day,
      to: to ?? day.add(const Duration(days: 1)),
      projectIds: projects,
      after: after,
      limit: limit,
    ),
  );

  test('an append carries its session\'s own copy', () {
    insertSession(db, 's1', at: h(9));
    final written = log.append([
      ActivityDraft(at: h(10), kind: ActivityKind.turnStarted, sessionId: 's1'),
    ]);
    expect(written.single.title, 'Title s1');
    expect(written.single.projectId, 'p1');
    expect(written.single.projectName, 'Alpha');
    expect(written.single.checkoutPath, '/Alpha');
    expect(written.single.agent, 'agentx');
    expect(written.single.machine, 'Desk');
    expect(written.single.source, 'live');
    expect(written.single.backfilled, isFalse);
  });

  test('an imported session is copied from its own row', () {
    insertImported(db, 'i1', repository: 'r2', at: h(8));
    final written = log.append([
      ActivityDraft(at: h(10), kind: ActivityKind.turnStarted, sessionId: 'i1'),
    ]);
    expect(written.single.title, 'Imported i1');
    expect(written.single.projectName, 'Beta');
    expect(written.single.machine, 'Desk');
  });

  test('a session already gone is copied from what was logged of it', () {
    insertSession(db, 's1', at: h(9));
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    final written = log.append([
      ActivityDraft(at: h(10), kind: ActivityKind.sessionEnded, sessionId: 's1'),
    ]);
    expect(written.single.title, 'Title s1');
    expect(written.single.projectName, 'Alpha');
  });

  test('an entry survives deleting its session, checkout and project, and '
      'still draws with its own title', () {
    insertSession(db, 's1', at: h(9));
    log.append([
      ActivityDraft(at: h(10), kind: ActivityKind.turnStarted, sessionId: 's1'),
    ]);
    db.execute("DELETE FROM sessions WHERE id = 's1';");
    db.execute("DELETE FROM repositories WHERE id = 'r1';");
    db.execute("DELETE FROM projects WHERE id = 'p1';");
    // The delete is logged by the trigger at SQLite's own now, the real clock,
    // not the test's day: read through to tomorrow so it falls inside the
    // range whatever date the suite runs on.
    final entries = rangeOf(
      to: DateTime.now().toUtc().add(const Duration(days: 1)),
    ).entries;
    expect(entries.map((e) => e.kind), [
      ActivityKind.sessionStarted,
      ActivityKind.turnStarted,
      ActivityKind.deleted,
    ]);
    expect(entries.map((e) => e.title).toSet(), {'Title s1'});
    expect(entries.map((e) => e.projectName).toSet(), {'Alpha'});
  });

  test('a keyed draft is written once however often it is appended', () {
    insertSession(db, 's1', at: h(9));
    final draft = ActivityDraft(
      at: h(10),
      kind: ActivityKind.turnStarted,
      sessionId: 's1',
      source: 'transcript',
      sourceId: 's1:0',
      backfilled: true,
    );
    expect(log.append([draft]), hasLength(1));
    expect(log.append([draft]), isEmpty);
    expect(
      rangeOf().entries.where((e) => e.kind == ActivityKind.turnStarted),
      hasLength(1),
    );
  });

  test('the range is oldest first, per project, and paged', () {
    insertSession(db, 'a', at: h(9));
    insertSession(db, 'b', repository: 'r2', at: h(9.5));
    log.append([
      for (var i = 0; i < 5; i++)
        ActivityDraft(
          at: h(10 + i),
          kind: i.isEven ? ActivityKind.turnStarted : ActivityKind.turnEnded,
          sessionId: 'a',
        ),
    ]);
    expect(rangeOf().entries, hasLength(7));
    expect(
      rangeOf(projects: ['p2']).entries.map((e) => e.sessionId).toSet(),
      {'b'},
    );

    final first = rangeOf(projects: ['p1'], limit: 4);
    expect(first.entries, hasLength(4));
    expect(first.next, isNotNull);
    final second = rangeOf(projects: ['p1'], limit: 4, after: first.next);
    expect(second.entries, hasLength(2));
    expect(second.next, isNull);
    final all = [...first.entries, ...second.entries];
    expect(all.map((e) => e.at), orderedEquals([...all.map((e) => e.at)]..sort()));
    expect(all.map((e) => e.id).toSet(), hasLength(6));
  });

  test('the first page carries in a session mid-turn as the range '
      'opened, and leaves out one that had ended or gone quiet', () {
    final yesterday = day.subtract(const Duration(hours: 3));
    insertSession(db, 'live', at: yesterday);
    insertSession(db, 'done', at: yesterday);
    log.append([
      ActivityDraft(
        at: yesterday.add(const Duration(hours: 1)),
        kind: ActivityKind.turnStarted,
        sessionId: 'live',
      ),
      ActivityDraft(
        at: yesterday.add(const Duration(hours: 1)),
        kind: ActivityKind.sessionEnded,
        sessionId: 'done',
      ),
    ]);
    final page = rangeOf();
    expect(page.entries.map((e) => (e.sessionId, e.kind)), [
      ('live', ActivityKind.sessionStarted),
      ('live', ActivityKind.turnStarted),
    ]);
    // A later page carries nothing in again.
    insertSession(db, 'today', at: h(1));
    final later = rangeOf(after: ActivityCursor(at: day, id: 0));
    expect(later.entries.map((e) => e.sessionId), ['today']);
  });

  test('tailing reads what was appended after an id', () {
    insertSession(db, 's1', at: h(9));
    final mark = log.lastId;
    log.append([
      ActivityDraft(at: h(10), kind: ActivityKind.turnStarted, sessionId: 's1'),
    ]);
    insertSession(db, 's2', at: h(11));
    expect(log.after(mark).map((e) => (e.sessionId, e.kind)), [
      ('s1', ActivityKind.turnStarted),
      ('s2', ActivityKind.sessionStarted),
    ]);
  });

  test('retention prunes what is older than the cut-off', () {
    insertSession(db, 'old', at: day.subtract(const Duration(days: 40)));
    insertSession(db, 'new', at: h(1));
    expect(log.prune(day.subtract(const Duration(days: 30))), 1);
    expect(
      log.after(0).map((e) => e.sessionId),
      ['new'],
    );
  });
}
