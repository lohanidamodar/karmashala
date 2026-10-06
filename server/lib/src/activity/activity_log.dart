import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';

/// How far back the first page of a range looks for what a session was doing
/// as the range opened.
const Duration kActivityCarryInLookback = Duration(days: 30);

/// One entry to append; its session's copy is read when it is written.
final class ActivityDraft {
  const ActivityDraft({
    required this.at,
    required this.kind,
    required this.sessionId,
    this.detail,
    this.parentSessionId,
    this.source = 'live',
    this.sourceId,
    this.backfilled = false,
    this.approximate = false,
  });

  final DateTime at;
  final ActivityKind kind;
  final String sessionId;
  final String? detail;
  final String? parentSessionId;
  final String source;

  /// The key a backfill is idempotent by; null for a live edge.
  final String? sourceId;
  final bool backfilled;
  final bool approximate;
}

typedef _Copy = ({
  String? title,
  String? projectId,
  String? projectName,
  String? checkoutPath,
  String? agent,
  String? machine,
  String? parentSessionId,
});

/// The `activity_log` table: append-only, read by range. Never joins to draw:
/// every row carries its own copy, taken here (or by the v80 triggers).
class ActivityLog {
  ActivityLog(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  static String _iso(DateTime at) => at.toUtc().toIso8601String();

  /// Appends [drafts] in one transaction and answers the entries written; a
  /// keyed draft already in the log is skipped.
  List<ActivityEntry> append(Iterable<ActivityDraft> drafts) {
    final list = drafts.toList();
    if (list.isEmpty) return const [];
    return _db.transaction(() {
      final copies = <String, _Copy>{};
      final ids = <int>[];
      final recordedAt = _iso(_clock());
      for (final draft in list) {
        final copy = copies[draft.sessionId] ??= _copyOf(draft.sessionId);
        final before = _changes;
        _db.execute(
          'INSERT OR IGNORE INTO activity_log (at, kind, session_id, title, '
          'project_id, project_name, checkout_path, agent, machine, '
          'parent_session_id, detail, source, source_id, backfilled, '
          'approximate, recorded_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
          [
            _iso(draft.at),
            draft.kind.name,
            draft.sessionId,
            copy.title,
            copy.projectId,
            copy.projectName,
            copy.checkoutPath,
            copy.agent,
            copy.machine,
            draft.parentSessionId ?? copy.parentSessionId,
            draft.detail,
            draft.source,
            draft.sourceId,
            draft.backfilled ? 1 : 0,
            draft.approximate ? 1 : 0,
            recordedAt,
          ],
        );
        if (_changes != before) ids.add(_db.lastInsertRowId);
      }
      if (ids.isEmpty) return const <ActivityEntry>[];
      return _entries(
        _db.query(
          'SELECT * FROM activity_log WHERE id IN '
          '(${List.filled(ids.length, '?').join(', ')}) ORDER BY id;',
          ids,
        ),
      );
    });
  }

  int get _changes =>
      _db.query('SELECT total_changes() AS n;').first['n']! as int;

  /// Session [sessionId]'s copy: its row, an imported row, or — once both
  /// are gone — what was last logged of it.
  _Copy _copyOf(String sessionId) {
    final native = _db.query(
      'SELECT s.title, r.project_id, p.name AS project_name, '
      'COALESCE(s.worktree_path, s.working_directory_path, r.path) '
      'AS checkout_path, a.agent_kind AS agent, e.name AS machine, '
      's.parent_session_id '
      'FROM sessions s '
      'LEFT JOIN repositories r ON r.id = s.repository_id '
      'LEFT JOIN projects p ON p.id = r.project_id '
      'LEFT JOIN agent_installations a ON a.id = s.agent_installation_id '
      'LEFT JOIN execution_environments e ON e.id = a.environment_id '
      'WHERE s.id = ?;',
      [sessionId],
    );
    final imported = native.isNotEmpty
        ? native
        : _db.query(
            'SELECT COALESCE(i.title, i.preview) AS title, r.project_id, '
            'p.name AS project_name, r.path AS checkout_path, '
            'i.source AS agent, e.name AS machine, '
            'NULL AS parent_session_id '
            'FROM imported_sessions i '
            'LEFT JOIN repositories r ON r.id = i.repository_id '
            'LEFT JOIN projects p ON p.id = r.project_id '
            'LEFT JOIN execution_environments e ON e.id = i.environment_id '
            'WHERE i.id = ?;',
            [sessionId],
          );
    final row = imported.isNotEmpty ? imported.first : const {};
    String? last(String column) {
      final value = row[column];
      if (value is String) return value;
      final logged = _db.query(
        'SELECT $column AS v FROM activity_log WHERE session_id = ? '
        'AND $column IS NOT NULL ORDER BY id DESC LIMIT 1;',
        [sessionId],
      );
      return logged.isEmpty ? null : logged.first['v'] as String?;
    }

    return (
      title: last('title'),
      projectId: last('project_id'),
      projectName: last('project_name'),
      checkoutPath: last('checkout_path'),
      agent: last('agent'),
      machine: last('machine'),
      parentSessionId: row['parent_session_id'] as String?,
    );
  }

  /// One page of [request]. The first page leads with each session that was
  /// mid-turn, waiting or paused as the range opened: its start and that entry.
  ActivityPage range(ActivityRange request) {
    final limit = request.limit.clamp(1, kActivityPageLimitMax);
    final projects = request.projectIds;
    final projectClause = projects == null
        ? ''
        : ' AND project_id IN (${List.filled(projects.length, '?').join(', ')})';
    final after = request.after;
    final rows = _db.query(
      'SELECT * FROM activity_log WHERE at >= ? AND at < ?$projectClause'
      '${after == null ? '' : ' AND (at > ? OR (at = ? AND id > ?))'} '
      'ORDER BY at, id LIMIT ?;',
      [
        _iso(request.from),
        _iso(request.to),
        ...?projects,
        if (after != null) ...[_iso(after.at), _iso(after.at), after.id],
        limit + 1,
      ],
    );
    final more = rows.length > limit;
    final page = _entries(more ? rows.sublist(0, limit) : rows);
    final next = more
        ? ActivityCursor(at: page.last.at, id: page.last.id)
        : null;
    if (after != null) return ActivityPage(entries: page, next: next);
    return ActivityPage(
      entries: [..._carryIn(request.from, projectClause, projects), ...page],
      next: next,
    );
  }

  List<ActivityEntry> _carryIn(
    DateTime from,
    String projectClause,
    List<String>? projects,
  ) {
    final latest = _db.query(
      'SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY session_id '
      'ORDER BY at DESC, id DESC) AS rn FROM activity_log '
      'WHERE at >= ? AND at < ?$projectClause) '
      "WHERE rn = 1 AND kind IN ('turnStarted', 'waitBegan', 'waitEnded', "
      "'limitPaused') "
      'ORDER BY at, id;',
      [_iso(from.subtract(kActivityCarryInLookback)), _iso(from), ...?projects],
    );
    if (latest.isEmpty) return const [];
    final sessions = [for (final row in latest) row['session_id']! as String];
    final starts = _db.query(
      "SELECT * FROM activity_log WHERE kind = 'sessionStarted' AND at < ? "
      'AND session_id IN (${List.filled(sessions.length, '?').join(', ')}) '
      'ORDER BY at, id;',
      [_iso(from), ...sessions],
    );
    final latestIds = {for (final row in latest) row['id']};
    return _entries([
      for (final row in starts)
        if (!latestIds.contains(row['id'])) row,
      ...latest,
    ]);
  }

  /// Everything appended after id [id], by id — the live tail.
  List<ActivityEntry> after(int id, {int limit = kActivityPageLimitMax}) =>
      _entries(
        _db.query(
          'SELECT * FROM activity_log WHERE id > ? ORDER BY id LIMIT ?;',
          [id, limit],
        ),
      );

  /// The kind of session [sessionId]'s newest entry, or null for none.
  ActivityKind? latestKind(String sessionId) {
    final rows = _db.query(
      'SELECT kind FROM activity_log WHERE session_id = ? '
      'ORDER BY at DESC, id DESC LIMIT 1;',
      [sessionId],
    );
    return rows.isEmpty
        ? null
        : ActivityKind.values.asNameMap()[rows.first['kind']];
  }

  /// The newest id, or 0 for an empty log.
  int get lastId =>
      _db.query('SELECT COALESCE(MAX(id), 0) AS n FROM activity_log;').first['n']!
          as int;

  /// Deletes everything that happened before [before]; answers how many.
  int prune(DateTime before) {
    final n = _db
        .query('SELECT COUNT(*) AS n FROM activity_log WHERE at < ?;', [
          _iso(before),
        ])
        .first['n']! as int;
    if (n > 0) {
      _db.execute('DELETE FROM activity_log WHERE at < ?;', [_iso(before)]);
    }
    return n;
  }

  static List<ActivityEntry> _entries(List<Map<String, Object?>> rows) => [
    for (final row in rows)
      if (ActivityKind.values.asNameMap()[row['kind']] case final kind?)
        ActivityEntry(
          id: row['id']! as int,
          at: DateTime.parse(row['at']! as String).toUtc(),
          kind: kind,
          sessionId: row['session_id']! as String,
          source: row['source']! as String,
          title: row['title'] as String?,
          projectId: row['project_id'] as String?,
          projectName: row['project_name'] as String?,
          checkoutPath: row['checkout_path'] as String?,
          agent: row['agent'] as String?,
          machine: row['machine'] as String?,
          parentSessionId: row['parent_session_id'] as String?,
          detail: row['detail'] as String?,
          backfilled: row['backfilled'] == 1,
          approximate: row['approximate'] == 1,
        ),
  ];
}
