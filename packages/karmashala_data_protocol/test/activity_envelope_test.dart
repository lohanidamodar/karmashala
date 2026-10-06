import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// The activity log — the timeline's history — through the envelope as JSON.
void main() {
  final t0 = DateTime.utc(2026, 10, 6, 9, 30);
  final entry = ActivityEntry(
    id: 7,
    at: t0,
    kind: ActivityKind.waitBegan,
    sessionId: 's1',
    title: 'Fix the build',
    projectId: 'p1',
    projectName: 'Alpha',
    checkoutPath: '/alpha',
    agent: 'agentx',
    machine: 'Desk',
    detail: 'allow write to app/lib/main.dart',
    source: 'live',
  );
  final backfilled = ActivityEntry(
    id: 8,
    at: t0,
    kind: ActivityKind.turnEnded,
    sessionId: 's2',
    parentSessionId: 's1',
    source: 'transcript',
    backfilled: true,
    approximate: true,
  );

  Object? overTheWire(Object? json) => jsonDecode(jsonEncode(json));

  test('an entry round-trips, with every optional copy and without', () {
    expect(
      ActivityEntry.fromJson(
        overTheWire(entry.toJson())! as Map<String, Object?>,
      ),
      entry,
    );
    final wire = overTheWire(backfilled.toJson())! as Map<String, Object?>;
    expect(wire.containsKey('title'), isFalse);
    expect(ActivityEntry.fromJson(wire), backfilled);
  });

  test('an entry of a kind this build does not know is refused', () {
    expect(
      () => ActivityEntry.fromJson({...entry.toJson(), 'kind': 'later'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('the ranged query round-trips its arguments and its page', () {
    final request = ActivityRange(
      from: t0,
      to: t0.add(const Duration(days: 1)),
      projectIds: const ['p1', 'p2'],
      after: ActivityCursor(at: t0, id: 7),
      limit: 500,
    );
    final read = DataRequest.fromJson(
      request.kind,
      overTheWire(request.argumentsToJson())! as Map<String, Object?>,
    );
    expect(read, isA<ActivityRange>());
    read as ActivityRange;
    expect(read.from, t0);
    expect(read.to, t0.add(const Duration(days: 1)));
    expect(read.projectIds, ['p1', 'p2']);
    expect(read.after, ActivityCursor(at: t0, id: 7));
    expect(read.limit, 500);

    final page = ActivityPage(
      entries: [entry, backfilled],
      next: ActivityCursor(at: t0, id: 8),
    );
    final answer = request.resultFromJson(
      overTheWire(request.resultToJson(page)),
    );
    expect(answer.entries, [entry, backfilled]);
    expect(answer.next, ActivityCursor(at: t0, id: 8));
  });

  test('every project and the first page are the defaults', () {
    final read =
        DataRequest.fromJson(ActivityRange.name, {
              'from': t0.toIso8601String(),
              'to': t0.toIso8601String(),
            })
            as ActivityRange;
    expect(read.projectIds, isNull);
    expect(read.after, isNull);
    expect(read.limit, kActivityPageLimit);
  });

  test('a page skips an entry this build cannot read rather than failing', () {
    final request = ActivityRange(from: t0, to: t0);
    final page = request.resultFromJson({
      'entries': [
        entry.toJson(),
        {...entry.toJson(), 'kind': 'later'},
      ],
    });
    expect(page.entries, [entry]);
    expect(page.next, isNull);
  });

  test('an append is pushed as a change', () {
    final change = DataChange.fromJson(
      overTheWire(ActivityAppended([entry]).toJson())! as Map<String, Object?>,
    );
    expect(change, isA<ActivityAppended>());
    expect((change as ActivityAppended).entries, [entry]);
  });
}
