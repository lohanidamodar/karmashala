import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';

/// Counts planner work rather than wall-clock time. A SEARCH is bounded by the
/// matching conversation rows; a SCAN grows with every session in the app.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  List<String> plan(String sql) => db
      .query('EXPLAIN QUERY PLAN $sql', [
        for (var i = 0; i < '?'.allMatches(sql).length; i++) '',
      ])
      .map((row) => row['detail']! as String)
      .toList();

  group('CLI conversation lookup', () {
    test('finds the newest session without a scan or temporary sort', () {
      expect(
        plan(
          'SELECT * FROM sessions WHERE external_session_id = ? '
          'ORDER BY created_at DESC, id DESC LIMIT 1;',
        ),
        [contains('SEARCH sessions USING INDEX idx_sessions_external')],
      );
    });

    test('finds every resumed session without scanning', () {
      expect(
        plan(
          'SELECT * FROM sessions WHERE external_session_id = ? '
          'ORDER BY created_at DESC, id DESC;',
        ),
        [contains('SEARCH sessions USING INDEX idx_sessions_external')],
      );
    });
  });

  test('whole-session reads remain explicit scans', () {
    expect(
      plan('SELECT * FROM sessions ORDER BY created_at, id;').first,
      contains('SCAN sessions'),
    );
  });
}
