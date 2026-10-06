import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// v76: a delegation keeps its child's last report — what it said, how, and
/// when — and is closed rather than deleted once it is no longer followed.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('the head is 76', () => expect(db.schemaVersion, 76));

  test('v76 adds the report and closing columns', () {
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
      ]),
    );
  });
}
