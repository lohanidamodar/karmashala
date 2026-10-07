import 'dart:convert';

import 'package:karmashala_store/database.dart';

import '../domain/automation_copy_rules.dart';
import '../domain/automation_json.dart' show stringMapFrom;
import '../service/automation_records.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/verdicts.dart';
import '../domain/automation.dart';
import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/automation_steps.dart';
import '../domain/automation_trigger.dart';
import '../domain/automation_webhook.dart';

/// Data access for automations and their occurrences. Hand-written SQL.
class AutomationDao implements AutomationRecords {
  AutomationDao(this._db);

  final AppDatabase _db;

  // --- automations ----------------------------------------------------------

  void insert(Automation automation) => _db.execute(
    'INSERT INTO automations '
    '(id, repository_id, name, cron, fires_at, every_seconds, '
    'agent_installation_id, prompt, permission_mode, enabled, armed_at, '
    'late_policy, stop_after_failures, consecutive_failures, '
    'disabled_reason, max_runtime_seconds, trigger_event, event_action, '
    'webhook_id, webhook_signature, webhook_model, webhook_worktree, '
    'webhook_per_hour, model_id, run_in_worktree, steps) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
    '?, ?, ?, ?, ?, ?, ?, ?);',
    [
      automation.id,
      automation.repositoryId,
      automation.name,
      ..._scheduleColumns(automation),
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
      automation.trigger?.kind.storedName,
      automation.trigger?.action.storedName,
      ..._webhookColumns(automation),
      ..._stepColumns(automation),
    ],
  );

  /// Replaces everything about [automation] but its id and its checkout.
  /// `armed_at` moves with an edit: changing it is authorising the new thing.
  void update(Automation automation) => _db.execute(
    'UPDATE automations SET name = ?, cron = ?, fires_at = ?, '
    'every_seconds = ?, agent_installation_id = ?, prompt = ?, '
    'permission_mode = ?, enabled = ?, armed_at = ?, late_policy = ?, '
    'stop_after_failures = ?, consecutive_failures = ?, disabled_reason = ?, '
    'max_runtime_seconds = ?, trigger_event = ?, event_action = ?, '
    'webhook_id = ?, webhook_signature = ?, webhook_model = ?, '
    'webhook_worktree = ?, webhook_per_hour = ?, model_id = ?, '
    'run_in_worktree = ?, steps = ? '
    'WHERE id = ?;',
    [
      automation.name,
      ..._scheduleColumns(automation),
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
      automation.trigger?.kind.storedName,
      automation.trigger?.action.storedName,
      ..._webhookColumns(automation),
      ..._stepColumns(automation),
      automation.id,
    ],
  );

  static List<Object?> _webhookColumns(Automation automation) {
    final webhook = automation.webhook;
    if (webhook == null) return const [null, null, null, null, null];
    return [
      webhook.hookId.isEmpty ? null : webhook.hookId,
      intFromBool(webhook.requireSignature),
      // Still written: a build before v84 reads a webhook's model here.
      automation.modelId,
      intFromBool(automation.worktree),
      webhook.callsPerHour,
    ];
  }

  static List<Object?> _stepColumns(Automation automation) => [
    automation.modelId,
    intFromBool(automation.worktree),
    automation.steps.toColumn(),
  ];

  /// cron, fires_at, every_seconds — all null for an event rule, so a build
  /// that predates triggers cannot read one as a schedule and fire it.
  static List<Object?> _scheduleColumns(Automation automation) {
    if (!automation.isScheduled) return const [null, null, null];
    final schedule = automation.schedule;
    return [
      schedule.cron,
      schedule.firesAt == null ? null : isoFromDate(schedule.firesAt!),
      schedule.everySeconds,
    ];
  }

  /// Records the outcome of one run against its automation's failure budget.
  ///
  /// A success clears the count **and** the reason it was disabled for, so an
  /// automation somebody re-enables after fixing it starts from zero rather
  /// than one failure away from stopping again.
  @override
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
  @override
  void disable(String id, String reason) => _db.execute(
    'UPDATE automations SET enabled = 0, disabled_reason = ? WHERE id = ?;',
    [reason, id],
  );

  /// Pauses or resumes one, leaving everything else — including its arming —
  /// alone. A paused automation is still authorised; it is just not due.
  @override
  void setEnabled(String id, {required bool enabled}) => _db.execute(
    'UPDATE automations SET enabled = ? WHERE id = ?;',
    [intFromBool(enabled), id],
  );

  void delete(String id) =>
      _db.execute('DELETE FROM automations WHERE id = ?;', [id]);

  @override
  Automation? getById(String id) {
    final rows = _db.query('SELECT * FROM automations WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _automation(rows.first);
  }

  @override
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

  /// The webhook automation whose URL ends in [hookId], enabled or not.
  Automation? byHookId(String hookId) {
    final rows = _db.query('SELECT * FROM automations WHERE webhook_id = ?;', [
      hookId,
    ]);
    return rows.isEmpty ? null : _automation(rows.first);
  }

  /// Every webhook automation, paused ones included.
  List<Automation> webhooks() => _db
      .query(
        'SELECT * FROM automations WHERE webhook_id IS NOT NULL '
        'ORDER BY name, id;',
      )
      .map(_automation)
      .toList();

  @override
  List<Automation> enabled() => _db
      .query('SELECT * FROM automations WHERE enabled = 1 ORDER BY name, id;')
      .map(_automation)
      .toList();

  /// Every event-triggered automation, paused ones included: a dry run has to
  /// be able to say "paused" rather than leave one out.
  @override
  List<Automation> eventRules() => _db
      .query(
        'SELECT * FROM automations WHERE trigger_event IS NOT NULL '
        'ORDER BY name, id;',
      )
      .map(_automation)
      .where((automation) => automation.isEventDriven)
      .toList();

  // --- origins: which automations led to a session's next event -------------

  /// The chain behind every event of [sessionId] because an automation started
  /// it, or empty. A time-based run's chain is just itself.
  @override
  List<String> originOfSession(String sessionId) {
    final run = runForSession(sessionId);
    if (run == null) return const [];
    return run.origin.isEmpty ? [run.automationId] : run.origin;
  }

  /// Records that an automation's message is going into [sessionId], so the
  /// turn it causes is known to be the automation's. Written *before* the
  /// message is typed: a fast turn must not finish ahead of the record.
  @override
  void markMessaged(String sessionId, List<String> origin, DateTime at) =>
      _db.execute(
        'INSERT INTO automation_session_origins (session_id, origin, '
        'recorded_at) VALUES (?, ?, ?) ON CONFLICT (session_id) DO UPDATE '
        'SET origin = excluded.origin, recorded_at = excluded.recorded_at;',
        [sessionId, jsonEncode(origin), isoFromDate(at)],
      );

  /// The chain a message left on [sessionId], or empty. [consume] clears it:
  /// only the one turn the message caused is the automation's.
  @override
  List<String> messagedOrigin(String sessionId, {bool consume = false}) {
    final rows = _db.query(
      'SELECT origin FROM automation_session_origins WHERE session_id = ?;',
      [sessionId],
    );
    if (rows.isEmpty) return const [];
    if (consume) clearMessaged(sessionId);
    return _ids(rows.first['origin'] as String?);
  }

  @override
  void clearMessaged(String sessionId) => _db.execute(
    'DELETE FROM automation_session_origins WHERE session_id = ?;',
    [sessionId],
  );

  // --- runs -----------------------------------------------------------------

  @override
  void insertRun(AutomationRun run) => _db.execute(
    'INSERT INTO automation_runs '
    '(id, automation_id, scheduled_for, fired_at, state, reason, '
    'base_checkpoint_id, session_id, finished_at, commits_made, origin, '
    'event_session_id, started_by, step_results, prompt, variables) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
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
      run.origin.isEmpty ? null : jsonEncode(run.origin),
      run.eventSessionId,
      run.startedBy?.name,
      _stepResultsColumn(run),
      run.prompt,
      run.variables.isEmpty ? null : jsonEncode(run.variables),
    ],
  );

  static String? _stepResultsColumn(AutomationRun run) =>
      run.stepResults.isEmpty
      ? null
      : jsonEncode([for (final step in run.stepResults) step.toJson()]);

  @override
  void updateRun(AutomationRun run) => _db.execute(
    'UPDATE automation_runs SET state = ?, reason = ?, base_checkpoint_id = ?, '
    'session_id = ?, finished_at = ?, commits_made = ?, step_results = ? '
    'WHERE id = ?;',
    [
      run.state.name,
      run.reason,
      run.baseCheckpointId,
      run.sessionId,
      run.finishedAt == null ? null : isoFromDate(run.finishedAt!),
      run.commitsMade,
      _stepResultsColumn(run),
      run.id,
    ],
  );

  // --- the checks one occurrence's work was measured with -------------------

  @override
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
  @override
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
  @override
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

  /// Forgiving the same way: an unreadable chain reads as none.
  static List<String> _ids(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final id in decoded)
          if (id is String && id.isNotEmpty) id,
      ];
    } on FormatException {
      return const [];
    }
  }

  @override
  AutomationRun? runById(String id) {
    final rows = _db.query('SELECT * FROM automation_runs WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _run(rows.first);
  }

  /// One automation's occurrences, newest due first.
  @override
  List<AutomationRun> runsFor(String automationId, {int limit = 50}) => _db
      .query(
        'SELECT * FROM automation_runs WHERE automation_id = ? '
        'ORDER BY scheduled_for DESC, fired_at DESC LIMIT ?;',
        [automationId, limit],
      )
      .map(_run)
      .toList();

  /// Runs fired before [before] (all, when null), newest first, at most
  /// [limit] — of [automationId] only, when one is named.
  List<AutomationRun> runsPage({
    DateTime? before,
    int limit = 50,
    String? automationId,
  }) {
    final at = before == null ? null : isoFromDate(before);
    return _db
        .query(
          'SELECT * FROM automation_runs WHERE (? IS NULL OR fired_at < ?) '
          'AND (? IS NULL OR automation_id = ?) '
          'ORDER BY fired_at DESC, id DESC LIMIT ?;',
          [at, at, automationId, automationId, limit],
        )
        .map(_run)
        .toList();
  }

  /// Every run still expecting something to happen, oldest due first — which
  /// is the order the queue drains in.
  @override
  List<AutomationRun> liveRuns() => _db
      .query(
        "SELECT * FROM automation_runs WHERE state IN ('queued', 'running') "
        'ORDER BY scheduled_for, fired_at;',
        const [],
      )
      .map(_run)
      .toList();

  @override
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
  @override
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
  @override
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
  @override
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
  @override
  DateTime? lastObservedOccurrence(String automationId) {
    final rows = _db.query(
      'SELECT MAX(scheduled_for) AS at FROM automation_runs '
      'WHERE automation_id = ?;',
      [automationId],
    );
    final value = rows.isEmpty ? null : rows.first['at'];
    return value == null ? null : dateFromIso(value);
  }

  // --- what a client's copy holds --------------------------------------------

  /// Every live run and the newest [perAutomation] of each automation.
  List<AutomationRun> copiedRuns({
    int perAutomation = kRunsCopiedPerAutomation,
  }) {
    final runs = {for (final run in liveRuns()) run.id: run};
    for (final automation in getAll()) {
      for (final run in runsFor(automation.id, limit: perAutomation)) {
        runs[run.id] = run;
      }
    }
    return [...runs.values];
  }

  /// Every verdict of [runIds], by run.
  Map<String, List<AutomationCheckVerdict>> checksOf(
    Iterable<String> runIds,
  ) => {
    for (final id in runIds)
      if (checksFor(id) case final checks when checks.isNotEmpty) id: checks,
  };

  /// Every origin chain a message left, by session.
  Map<String, List<String>> origins() => {
    for (final row in _db.query(
      'SELECT session_id, origin FROM automation_session_origins;',
    ))
      row['session_id']! as String: _ids(row['origin'] as String?),
  };

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
      trigger: AutomationEventTrigger.fromRow(
        event: row['trigger_event'] as String?,
        action: row['event_action'] as String?,
      ),
      webhook: row['webhook_id'] == null
          ? null
          : AutomationWebhook(
              hookId: row['webhook_id']! as String,
              requireSignature: boolFromInt(row['webhook_signature'] ?? 1),
              callsPerHour:
                  row['webhook_per_hour'] as int? ??
                  kDefaultWebhookCallsPerHour,
            ),
      modelId: row['model_id'] as String?,
      worktree: boolFromInt(row['run_in_worktree'] ?? 0),
      steps: AutomationSteps.fromColumn(row['steps'] as String?),
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
    origin: _ids(row['origin'] as String?),
    eventSessionId: row['event_session_id'] as String?,
    startedBy: AutomationRunCause.fromName(row['started_by'] as String?),
    stepResults: AutomationStepResult.listFromColumn(
      row['step_results'] as String?,
    ),
    prompt: row['prompt'] as String?,
    variables: _variables(row['variables'] as String?),
  );

  static Map<String, String> _variables(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      return stringMapFrom(jsonDecode(raw));
    } on FormatException {
      return const {};
    }
  }
}
