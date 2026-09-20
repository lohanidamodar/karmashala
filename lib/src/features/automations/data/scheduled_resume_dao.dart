import 'package:karmashala_store/database.dart';

import '../domain/scheduled_resume.dart';

/// Data access for scheduled resumes. Hand-written SQL.
class ScheduledResumeDao {
  ScheduledResumeDao(this._db);

  final AppDatabase _db;

  static const _live = "('pending', 'queued', 'firing')";

  /// Arms [resume], ending whatever was live for its session: one per session,
  /// and the newest is the one the user meant.
  void replaceFor(ScheduledResume resume, {required DateTime now}) =>
      _db.transaction(() {
        _db.execute(
          'UPDATE scheduled_resumes SET state = ?, reason = ?, finished_at = ? '
          'WHERE session_id = ? AND state IN $_live;',
          [
            ScheduledResumeState.cancelled.name,
            'Replaced by a newer schedule.',
            isoFromDate(now),
            resume.sessionId,
          ],
        );
        _db.execute(
          'INSERT INTO scheduled_resumes '
          '(id, session_id, account_key, account_email, window_label, '
          'resets_at, fire_at, message, permission_mode, notify, late_policy, '
          'state, reason, attempts, live_when_scheduled, scheduled_by, '
          'scheduled_at, finished_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
          [
            resume.id,
            resume.sessionId,
            resume.accountKey,
            resume.accountEmail,
            resume.windowLabel,
            _iso(resume.resetsAt),
            isoFromDate(resume.fireAt),
            resume.message,
            resume.permissionMode,
            intFromBool(resume.notify),
            resume.latePolicy.name,
            resume.state.name,
            resume.reason,
            resume.attempts,
            intFromBool(resume.liveWhenScheduled),
            resume.scheduledBy,
            isoFromDate(resume.scheduledAt),
            _iso(resume.finishedAt),
          ],
        );
      });

  /// Writes what moves after arming. What the user chose never changes; a
  /// different choice is a new row.
  void update(ScheduledResume resume) => _db.execute(
    'UPDATE scheduled_resumes SET account_key = ?, account_email = ?, '
    'resets_at = ?, fire_at = ?, state = ?, reason = ?, attempts = ?, '
    'finished_at = ? WHERE id = ?;',
    [
      resume.accountKey,
      resume.accountEmail,
      _iso(resume.resetsAt),
      isoFromDate(resume.fireAt),
      resume.state.name,
      resume.reason,
      resume.attempts,
      _iso(resume.finishedAt),
      resume.id,
    ],
  );

  /// Moves [id] from one state to another, and says whether it did. The guard
  /// is what keeps two ticks from both firing one row.
  bool transition(
    String id, {
    required ScheduledResumeState from,
    required ScheduledResumeState to,
  }) {
    _db.execute(
      'UPDATE scheduled_resumes SET state = ? WHERE id = ? AND state = ?;',
      [to.name, id, from.name],
    );
    return _db.query('SELECT changes() AS n;').first['n'] == 1;
  }

  ScheduledResume? getById(String id) {
    final rows = _db.query('SELECT * FROM scheduled_resumes WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// The one live row for [sessionId], or null.
  ScheduledResume? liveFor(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM scheduled_resumes WHERE session_id = ? '
      'AND state IN $_live LIMIT 1;',
      [sessionId],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// The newest ended row for [sessionId], or null. What says whether this
  /// session has a standing arrangement to resume when its limit resets, and
  /// how the last one ended — a cancelled one is the user calling it off.
  ScheduledResume? lastEndedFor(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM scheduled_resumes WHERE session_id = ? '
      'AND state NOT IN $_live '
      'ORDER BY COALESCE(finished_at, fire_at) DESC LIMIT 1;',
      [sessionId],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// Every live row, soonest first.
  List<ScheduledResume> live() => _db
      .query(
        'SELECT * FROM scheduled_resumes WHERE state IN $_live '
        'ORDER BY fire_at, scheduled_at;',
      )
      .map(_row)
      .toList();

  List<ScheduledResume> inState(ScheduledResumeState state) => _db
      .query(
        'SELECT * FROM scheduled_resumes WHERE state = ? '
        'ORDER BY fire_at, scheduled_at;',
        [state.name],
      )
      .map(_row)
      .toList();

  /// The newest ended rows, for the page's record of what happened.
  List<ScheduledResume> recentEnded({int limit = 20}) => _db
      .query(
        'SELECT * FROM scheduled_resumes WHERE state NOT IN $_live '
        'ORDER BY COALESCE(finished_at, fire_at) DESC LIMIT ?;',
        [limit],
      )
      .map(_row)
      .toList();

  void delete(String id) =>
      _db.execute('DELETE FROM scheduled_resumes WHERE id = ?;', [id]);

  static String? _iso(DateTime? at) => at == null ? null : isoFromDate(at);

  static DateTime? _date(Object? value) =>
      value == null ? null : dateFromIso(value);

  ScheduledResume _row(Map<String, Object?> row) => ScheduledResume(
    id: row['id']! as String,
    sessionId: row['session_id']! as String,
    accountKey: row['account_key'] as String? ?? '',
    accountEmail: row['account_email'] as String?,
    windowLabel: row['window_label'] as String?,
    resetsAt: _date(row['resets_at']),
    fireAt: dateFromIso(row['fire_at']),
    message: row['message'] as String? ?? '',
    permissionMode: row['permission_mode'] as String?,
    notify: boolFromInt(row['notify']),
    latePolicy: ResumeLatePolicy.fromName(row['late_policy'] as String?),
    state: ScheduledResumeState.fromName(row['state'] as String?),
    reason: row['reason'] as String? ?? '',
    attempts: row['attempts'] as int? ?? 0,
    liveWhenScheduled: boolFromInt(row['live_when_scheduled']),
    scheduledBy: row['scheduled_by'] as String? ?? 'the user',
    scheduledAt: dateFromIso(row['scheduled_at']),
    finishedAt: _date(row['finished_at']),
  );
}
