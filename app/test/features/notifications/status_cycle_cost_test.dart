import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:sqlite3/sqlite3.dart';

import '../terminal/fake_instance.dart';

/// What reading already-loaded native-session terminal tails costs in SQL.
///
/// The status loader has already decoded every session row. Before the pane id
/// was carried with that result, the tail callback called `SessionDao.getById`
/// again for every native session on every status cycle. This pins the
/// useful unit: 100 sessions must add zero statements, not 100 duplicate row
/// lookups.
void main() {
  test('terminal tails add no database statement per watched session', () {
    final db = _CountingDatabase();
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    addTearDown(db.close);

    // Mount the controller before measuring; its two bootstrap reads are an
    // app-lifetime cost, not work a status cycle causes.
    container.read(_tailProvider('warm-up'));
    db.reset();
    for (var i = 0; i < 100; i++) {
      container.read(_tailProvider('missing-pane-$i'));
    }

    // ignore: avoid_print
    print('STATUS-TAIL sessions=100 statements=${db.statements}');
    expect(
      db.statements,
      0,
      reason: 'the loader already read these rows; the tail needs only paneId',
    );
  });
}

final _tailProvider = Provider.family<List<String>, String>(
  (ref, paneId) => sessionTerminalTailForPane(ref, paneId),
);

class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int statements = 0;

  void reset() => statements = 0;

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements++;
    return super.query(sql, params);
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements++;
    super.execute(sql, params);
  }
}
