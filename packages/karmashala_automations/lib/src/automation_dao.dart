import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/verdicts.dart';
import 'automation.dart';
import 'automation_check_verdict.dart';
import 'automation_run.dart';

/// Data access for automations and their occurrences. Hand-written SQL.
class AutomationDao {
  AutomationDao(this._db);

  final AppDatabase _db;

  // --- automations ----------------------------------------------------------

  void insert(Automation automation) => _db.execute(
    'INSERT INTO automations '
    '(id, repository_id, name, cron, fires_at, every_seconds, '
    'agent_installation_id, prompt, permission_mode, enabled, armed_at, '
    'late_policy, stop_after_failures, consecutive_failures, '
    'disabled_reason, max_runtime_seconds) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      automation.id,
      automation.repositoryId,
      automation.name,
      automation.schedule.cron,
      automation.schedule.firesAt == null
          ? null
          : isoFromDate(automation.schedule.firesAt!),
      automation.schedule.everySeconds,
      automation.agentInstallationId,
      automation.prompt,
      automation.permissionMode?.canonical,
      intFromBool(automation.enabled),
      isoFromDate(automation.armedAt),
      automation.latePolicy.name,
      automation.stopAfterFailures,
      automation.consecutiveFailures,
      automation.disabledReason,
      automation.maxRuntime?.inSeconds,
    ],
  );

  /// Replaces everything about [automation] but its id and its checkout.
  /// `armed_at` moves with an edit: changing it is authorising the new thing.
  void update(Automation automation) => _db.execute(
    'UPDATE automations SET name = ?, cron = ?, fires_at = ?, '
    'every_seconds = ?, agent_installation_id = ?, prompt = ?, '
    'permission_mode = ?, enabled = ?, armed_at = ?, late_policy = ?, '
    'stop_after_failures = ?, consecutive_failures = ?, disabled_reason = ?, '
    'max_runtime_seconds = ? WHERE id = ?;',
    [
      automation.name,
      automation.schedule.cron,
      automation.schedule.firesAt == null
          ? null
          : isoFromDate(automation.schedule.firesAt!),
      automation.schedule.everySeconds,
      automation.agentInstallationId,
      automation.prompt,
      automation.permissionMode?.canonical,
      intFromBool(automation.enabled),
      isoFromDate(automation.armedAt),
      automation.latePolicy.name,
      automation.stopAfterFailures,
      automation.consecutiveFailures,
      automation.disabledReason,
      automation.maxRuntime?.inSeconds,
      automation.id,
    ],
  );

  /// Records the outcome of one run against its automation's failure budget.
  ///
  /// A success clears the count **and** the reason it was disabled for, so an
  /// automation somebody re-enables after fixing it starts from zero rather
  /// than one failure away from stopping again.
  void recordOutcome(String id, {required bool failed}) {
    if (!failed) {
      _db.execute(
        'UPDATE automations SET consecutive_failures = 0, '
        'disabled_reason = NULL WHERE id = ?;',
        [id],
      );
      return;
    }
    _db.execute(
      'UPDATE automations SET consecutive_failures = consecutive_failures + 1 '
      'WHERE id = ?;',
      [id],
    );
  }

  /// Disables [id] and says why — the one disabling nobody asked for, so it
  /// must never be silent.
  void disable(String id, String reason) => _db.execute(
    'UPDATE automations SET enabled = 0, disabled_reason = ? WHERE id = ?;',
    [reason, id],
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

  /// When this automation's last run **ended**, or null when none has.
  ///
  /// What an interval schedule counts its gap from. Deliberately the finish
  /// and not the occurrence: a gap measured from the start would let a run
  /// that overran be followed immediately by the next one, which is the
  /// overlap the interval kind exists to prevent.
  DateTime? lastFinishedAt(String automationId) {
    final rows = _db.query(
      'SELECT MAX(finished_at) AS at FROM automation_runs '
      'WHERE automation_id = ? AND finished_at IS NOT NULL;',
      [automationId],
    );
    final value = rows.isEmpty ? null : rows.first['at'];
    return value == null ? null : dateFromIso(value);
  }

  /// Whether this automation has a run of its own still live — the guard that
  /// stops two occurrences of *one* automation stacking, which the
  /// per-checkout guard does not catch when they are in different checkouts.
  AutomationRun? liveRunOf(String automationId) {
    for (final run in liveRuns()) {
      if (run.automationId == automationId) return run;
    }
    return null;
  }

  /// When this install last *did* anything about this automation — fired it,
  /// queued it, or filed a miss — or null when it never has.
  ///
  /// An interval counts from this rather than from the occurrence it last
  /// recorded. The difference only shows on a miss: filing "the 17:10 one was
  /// too late" and then counting from 17:10 makes 17:20 immediately due too,
  /// and a ten-hour sleep files sixty misses one tick at a time. Counting from
  /// when the miss was *filed* says the honest thing instead — the backlog is
  /// not being worked through, and the next one is a gap from now.
  DateTime? lastTouchedAt(String automationId) {
    final rows = _db.query(
      'SELECT MAX(fired_at) AS at FROM automation_runs WHERE automation_id = ?;',
      [automationId],
    );
    final value = rows.isEmpty ? null : rows.first['at'];
    return value == null ? null : dateFromIso(value);
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
    final firesAt = row['fires_at'];
    final schedule = AutomationSchedule.fromRow(
      cron: row['cron'] as String?,
      firesAt: firesAt == null ? null : dateFromIso(firesAt),
      everySeconds: row['every_seconds'] as int?,
    );
    final seconds = row['max_runtime_seconds'] as int?;
    return Automation(
      id: row['id']! as String,
      repositoryId: row['repository_id']! as String,
      name: row['name']! as String,
      // A row naming no schedule at all cannot come out of `insert`; reading
      // one as a one-shot in the past is the reading that fires nothing.
      schedule:
          schedule ?? AutomationSchedule.once(dateFromIso(row['armed_at'])),
      agentInstallationId: row['agent_installation_id']! as String,
      prompt: row['prompt']! as String,
      permissionMode: PermissionSelection.parse(
        row['permission_mode'] as String?,
      ),
      enabled: boolFromInt(row['enabled']),
      armedAt: dateFromIso(row['armed_at']),
      latePolicy: AutomationLatePolicy.fromName(row['late_policy'] as String?),
      stopAfterFailures:
          row['stop_after_failures'] as int? ?? kDefaultStopAfterFailures,
      consecutiveFailures: row['consecutive_failures'] as int? ?? 0,
      disabledReason: row['disabled_reason'] as String?,
      maxRuntime: seconds == null || seconds <= 0
          ? null
          : Duration(seconds: seconds),
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
