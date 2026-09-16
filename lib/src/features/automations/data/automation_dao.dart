import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/descriptors.dart';
import '../../verification/domain/verification_run.dart';
import '../domain/automation.dart';
import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';

/// Data access for automations and their occurrences. Hand-written SQL.
class AutomationDao {
  AutomationDao(this._db);

  final AppDatabase _db;

  // --- automations ----------------------------------------------------------

  void insert(Automation automation) => _db.execute(
    'INSERT INTO automations '
    '(id, repository_id, name, cron, fires_at, agent_installation_id, prompt, '
    'permission_mode, enabled, armed_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      automation.id,
      automation.repositoryId,
      automation.name,
      automation.schedule.cron,
      automation.schedule.firesAt == null
          ? null
          : isoFromDate(automation.schedule.firesAt!),
      automation.agentInstallationId,
      automation.prompt,
      automation.permissionMode?.canonical,
      intFromBool(automation.enabled),
      isoFromDate(automation.armedAt),
    ],
  );

  /// Replaces everything about [automation] but its id and its checkout.
  /// `armed_at` moves with an edit: changing it is authorising the new thing.
  void update(Automation automation) => _db.execute(
    'UPDATE automations SET name = ?, cron = ?, fires_at = ?, '
    'agent_installation_id = ?, prompt = ?, permission_mode = ?, enabled = ?, '
    'armed_at = ? WHERE id = ?;',
    [
      automation.name,
      automation.schedule.cron,
      automation.schedule.firesAt == null
          ? null
          : isoFromDate(automation.schedule.firesAt!),
      automation.agentInstallationId,
      automation.prompt,
      automation.permissionMode?.canonical,
      intFromBool(automation.enabled),
      isoFromDate(automation.armedAt),
      automation.id,
    ],
  );

  /// Pauses or resumes one, leaving everything else — including its arming —
  /// alone. A paused automation is still authorised; it is just not due.
  void setEnabled(String id, {required bool enabled}) => _db.execute(
    'UPDATE automations SET enabled = ? WHERE id = ?;',
    [intFromBool(enabled), id],
  );

  void delete(String id) =>
      _db.execute('DELETE FROM automations WHERE id = ?;', [id]);

  Automation? getById(String id) {
    final rows = _db.query('SELECT * FROM automations WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _automation(rows.first);
  }

  List<Automation> getAll() => _db
      .query('SELECT * FROM automations ORDER BY name, id;')
      .map(_automation)
      .toList();

  List<Automation> forRepository(String repositoryId) => _db
      .query(
        'SELECT * FROM automations WHERE repository_id = ? ORDER BY name, id;',
        [repositoryId],
      )
      .map(_automation)
      .toList();

  List<Automation> enabled() => _db
      .query('SELECT * FROM automations WHERE enabled = 1 ORDER BY name, id;')
      .map(_automation)
      .toList();

  // --- runs -----------------------------------------------------------------

  void insertRun(AutomationRun run) => _db.execute(
    'INSERT INTO automation_runs '
    '(id, automation_id, scheduled_for, fired_at, state, reason, '
    'base_checkpoint_id, session_id, finished_at, commits_made) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      run.id,
      run.automationId,
      isoFromDate(run.scheduledFor),
      isoFromDate(run.firedAt),
      run.state.name,
      run.reason,
      run.baseCheckpointId,
      run.sessionId,
      run.finishedAt == null ? null : isoFromDate(run.finishedAt!),
      run.commitsMade,
    ],
  );

  void updateRun(AutomationRun run) => _db.execute(
    'UPDATE automation_runs SET state = ?, reason = ?, base_checkpoint_id = ?, '
    'session_id = ?, finished_at = ?, commits_made = ? WHERE id = ?;',
    [
      run.state.name,
      run.reason,
      run.baseCheckpointId,
      run.sessionId,
      run.finishedAt == null ? null : isoFromDate(run.finishedAt!),
      run.commitsMade,
      run.id,
    ],
  );

  // --- the checks one occurrence's work was measured with -------------------

  void insertRunCheck(AutomationCheckVerdict verdict) => _db.execute(
    'INSERT INTO automation_run_checks '
    '(run_id, ordinal, check_id, name, command, verdict, reason, '
    'verification_run_id, checked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      verdict.runId,
      verdict.ordinal,
      verdict.checkId,
      verdict.name,
      jsonEncode(verdict.command),
      verdict.verdict.name,
      verdict.reason,
      verdict.verificationRunId,
      isoFromDate(verdict.checkedAt),
    ],
  );

  /// One run's verdicts, in the order the checks ran.
  List<AutomationCheckVerdict> checksFor(String runId) => _db
      .query(
        'SELECT * FROM automation_run_checks WHERE run_id = ? ORDER BY '
        'ordinal;',
        [runId],
      )
      .map(_checkVerdict)
      .toList();

  /// Records that this run's checks were looked at, whatever they said. Without
  /// the timestamp, "no verdicts" cannot be told from "nobody looked".
  void noteChecksObserved(String runId, DateTime at) => _db.execute(
    'UPDATE automation_runs SET checks_observed_at = ? WHERE id = ?;',
    [isoFromDate(at), runId],
  );

  AutomationCheckVerdict _checkVerdict(Map<String, Object?> row) =>
      AutomationCheckVerdict(
        runId: row['run_id']! as String,
        ordinal: row['ordinal']! as int,
        checkId: row['check_id'] as String?,
        name: row['name']! as String,
        command: _argv(row['command'] as String?),
        // A word this build cannot read is not a pass and not a fail;
        // inconclusive is the only answer that claims nothing.
        verdict:
            VerificationVerdict.parse(row['verdict'] as String?) ??
            VerificationVerdict.inconclusive,
        reason: row['reason'] as String? ?? '',
        verificationRunId: row['verification_run_id'] as String?,
        checkedAt: dateFromIso(row['checked_at']),
      );

  /// Forgiving like `ProjectCheckDao._argv`: one unreadable row must not stop a
  /// run's other verdicts being read.
  static List<String> _argv(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final part in decoded)
          if (part is String && part.isNotEmpty) part,
      ];
    } on FormatException {
      return const [];
    }
  }

  AutomationRun? runById(String id) {
    final rows = _db.query('SELECT * FROM automation_runs WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _run(rows.first);
  }

  /// One automation's occurrences, newest due first.
  List<AutomationRun> runsFor(String automationId, {int limit = 50}) => _db
      .query(
        'SELECT * FROM automation_runs WHERE automation_id = ? '
        'ORDER BY scheduled_for DESC, fired_at DESC LIMIT ?;',
        [automationId, limit],
      )
      .map(_run)
      .toList();

  /// Every run still expecting something to happen, oldest due first — which
  /// is the order the queue drains in.
  List<AutomationRun> liveRuns() => _db
      .query(
        "SELECT * FROM automation_runs WHERE state IN ('queued', 'running') "
        'ORDER BY scheduled_for, fired_at;',
        const [],
      )
      .map(_run)
      .toList();

  AutomationRun? runForSession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM automation_runs WHERE session_id = ? '
      'ORDER BY fired_at DESC LIMIT 1;',
      [sessionId],
    );
    return rows.isEmpty ? null : _run(rows.first);
  }

  /// The newest occurrence this install has recorded anything about, or null —
  /// the floor a missed-fire sweep counts from.
  DateTime? lastObservedOccurrence(String automationId) {
    final rows = _db.query(
      'SELECT MAX(scheduled_for) AS at FROM automation_runs '
      'WHERE automation_id = ?;',
      [automationId],
    );
    final value = rows.isEmpty ? null : rows.first['at'];
    return value == null ? null : dateFromIso(value);
  }

  Automation _automation(Map<String, Object?> row) {
    final cron = row['cron'] as String?;
    final firesAt = row['fires_at'];
    return Automation(
      id: row['id']! as String,
      repositoryId: row['repository_id']! as String,
      name: row['name']! as String,
      schedule: cron != null && cron.isNotEmpty
          ? AutomationSchedule.cron(cron)
          : AutomationSchedule.once(dateFromIso(firesAt)),
      agentInstallationId: row['agent_installation_id']! as String,
      prompt: row['prompt']! as String,
      permissionMode: PermissionSelection.parse(row['permission_mode'] as String?),
      enabled: boolFromInt(row['enabled']),
      armedAt: dateFromIso(row['armed_at']),
    );
  }

  AutomationRun _run(Map<String, Object?> row) => AutomationRun(
    id: row['id']! as String,
    automationId: row['automation_id']! as String,
    scheduledFor: dateFromIso(row['scheduled_for']),
    firedAt: dateFromIso(row['fired_at']),
    state: AutomationRunState.fromName(row['state'] as String?),
    reason: row['reason'] as String? ?? '',
    baseCheckpointId: row['base_checkpoint_id'] as String?,
    sessionId: row['session_id'] as String?,
    finishedAt: row['finished_at'] == null
        ? null
        : dateFromIso(row['finished_at']),
    commitsMade: row['commits_made'] as int?,
    checksObservedAt: row['checks_observed_at'] == null
        ? null
        : dateFromIso(row['checks_observed_at']),
  );
}
