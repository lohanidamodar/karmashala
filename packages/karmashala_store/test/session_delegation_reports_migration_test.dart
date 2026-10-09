import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v77: a delegation keeps its child's last report — what it said, how, and
/// when — and is closed rather than deleted once it is no longer followed.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 91', () => expect(db.schemaVersion, 91));

  test('v77 adds the report and closing columns', () {
    final columns = db
        .query('PRAGMA table_info(session_delegations);')
        .map((r) => r['name']! as String)
        .toList();
    expect(
      columns,
      containsAllInOrder([
        'turn_started_at',
        'report_state',
        'report_via',
        'reported_at',
        'closed_at',
        'report_mode',
        'report_text',
        'report_delivered',
      ]),
    );
  });
}
