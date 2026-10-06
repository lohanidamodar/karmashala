import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/activity/activity_log.dart';
import 'package:karmashala_host/src/activity/activity_writer.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'activity_fixture.dart';

/// The timeline reads the log over the data channel: a ranged query, and
/// what is appended pushed as it lands.
void main() {
  late AppDatabase db;
  late DataService service;
  final day = DateTime.utc(2026, 10, 6);

  setUp(() {
    db = activityStore();
    service = DataService(db, clock: () => day.add(const Duration(hours: 12)));
  });
  tearDown(() => db.close());

  test('a client reads a day of one project, and nothing else', () async {
    insertSession(db, 'a', at: day.add(const Duration(hours: 9)));
    insertSession(db, 'b', repository: 'r2', at: day.add(const Duration(hours: 9)));
    insertSession(db, 'old', at: day.subtract(const Duration(days: 2)));
    final reply = service
        .open((_) {})
        .handle(
          ActivityRange(
            from: day,
            to: day.add(const Duration(days: 1)),
            projectIds: const ['p1'],
          ),
        );
    expect(reply.value.entries.map((e) => e.sessionId), ['a']);
  });

  test('an append is pushed to subscribed clients as it lands', () async {
    final told = <DataChanges>[];
    service.open(told.add).handle(const DataSubscribe());
    final writer = ActivityWriter(
      append: service.activity.append,
      tail: service.activity.after,
      lastId: service.activity.lastId,
      announce: (entries) => service.announce([ActivityAppended(entries)]),
      delay: const Duration(milliseconds: 1),
    );
    insertSession(db, 'a', at: day);
    writer.record(
      ActivityDraft(
        at: day.add(const Duration(minutes: 5)),
        kind: ActivityKind.turnStarted,
        sessionId: 'a',
      ),
    );
    await writer.flushed;
    final appended = told
        .expand((batch) => batch.changes)
        .whereType<ActivityAppended>()
        .single;
    expect(appended.entries.map((e) => e.kind), [
      ActivityKind.sessionStarted,
      ActivityKind.turnStarted,
    ]);
    await writer.close();
  });
}
