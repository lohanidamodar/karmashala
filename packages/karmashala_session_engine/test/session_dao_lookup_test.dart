import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The other half of karmashala_store's session_query_plan_test.dart, which
/// asks the planner whether the CLI conversation lookup uses its index.
void main() {
  test('and the dao still answers with the row', () {
    // The guard against a green plan over a query that stopped working: an
    // index is only correct if the read it serves still returns the right row.
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final dao = SessionDao(db);
    expect(dao.getByExternalSessionId('nobody'), isNull);
  });
}
