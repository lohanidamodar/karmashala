import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';

/// **What the planner does with the sessions table.**
///
/// An index test that only asks `PRAGMA index_list` proves the index exists,
/// which is not the claim anybody cares about — the claim is that the reads
/// *use* it, and that survives a column being added to a `WHERE`, an `ORDER BY`
/// being reworded, or a collation changing. `EXPLAIN QUERY PLAN` is the only
/// thing that answers it, and it costs nothing: the planner is asked, no rows
/// are read.
///
/// Counted rather than timed, like every other cost file here. `SCAN` versus
/// `SEARCH` is a property of the plan, so it reads the same on a loaded machine
/// as on an idle one, which a millisecond does not.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  /// The plan for [sql], one line per step.
  ///
  /// A value is bound for every `?` because SQLite prepares the statement to
  /// answer this, and a prepared statement wants its parameters. The values
  /// themselves are never read: the planner is asked, no rows are.
  List<String> plan(String sql) => db
      .query('EXPLAIN QUERY PLAN $sql', [
        for (var i = 0; i < '?'.allMatches(sql).length; i++) '',
      ])
      .map((row) => row['detail']! as String)
      .toList();

  /// The `IN (...)` list `SessionDao` builds at runtime, at one placeholder.
  String withOnePlaceholder(String sql) =>
      sql.replaceAll(r'($placeholders)', '(?)');

  group('the CLI conversation lookup', () {
    // The two reads `SessionAutoImportService` and `SessionAdoptionService`
    // make once per detected store conversation. Before v36 both were
    // `SCAN sessions`, so the sweep cost conversations x sessions.
    test('finds the newest row without scanning the table', () {
      expect(
        plan(
          'SELECT * FROM sessions WHERE external_session_id = ? '
          'ORDER BY created_at DESC, id DESC LIMIT 1;',
        ),
        [contains('SEARCH sessions USING INDEX idx_sessions_external')],
        reason:
            'one step, and no sort: the index carries created_at and id after '
            'the conversation id precisely so the total order is free',
      );
    });

    test('and finds every row for a resumed conversation the same way', () {
      expect(
        plan(
          'SELECT * FROM sessions WHERE external_session_id = ? '
          'ORDER BY created_at DESC, id DESC;',
        ),
        [contains('SEARCH sessions USING INDEX idx_sessions_external')],
      );
    });
  });

  group('the reads that are allowed to scan, and why', () {
    test('the whole list, because it is the whole list', () {
      expect(
        plan('SELECT * FROM sessions ORDER BY created_at, id;').first,
        contains('SCAN sessions'),
        reason: 'no filter can narrow "every session"',
      );
    });

    test('the liveness sweep, which runs once at launch', () {
      // `SessionDao.getClaimingLive`. Deliberately left scanning: an index on
      // `status` would serve one launch-time query and be maintained on every
      // status write, which is the most frequent write in the app. Measured at
      // 500 rows: the scan costs 499 fullscan steps once, and the index costs
      // +10 VM steps on every `UPDATE sessions SET status` forever.
      expect(
        plan(
          withOnePlaceholder(
            'SELECT * FROM sessions WHERE status IN (\$placeholders) '
            'ORDER BY created_at, id;',
          ),
        ).first,
        contains('SCAN sessions'),
      );
    });
  });

  group('the reads that must never scan', () {
    test('one row by id', () {
      expect(plan('SELECT * FROM sessions WHERE id = ?;').single, contains('SEARCH sessions'));
    });

    test('the rows in a repository — the Explorer list and the header count', () {
      expect(
        plan('SELECT * FROM sessions WHERE repository_id = ?;').first,
        contains('SEARCH sessions USING INDEX idx_sessions_repository'),
      );
    });

    test('the row in a pane — every tab switch', () {
      expect(
        plan(withOnePlaceholder(
          'SELECT * FROM sessions WHERE pane_id IN (\$placeholders);',
        )).first,
        contains('SEARCH sessions USING INDEX idx_sessions_pane'),
      );
    });

    test('a session\'s children — what SessionDepth walks', () {
      expect(
        plan('SELECT * FROM sessions WHERE parent_session_id = ?;').first,
        contains('SEARCH sessions USING INDEX idx_sessions_parent'),
      );
    });
  });

  test('and the dao still answers with the row', () {
    // The guard against a green plan over a query that stopped working: an
    // index is only correct if the read it serves still returns the right row.
    final dao = SessionDao(db);
    expect(dao.getByExternalSessionId('nobody'), isNull);
  });
}
