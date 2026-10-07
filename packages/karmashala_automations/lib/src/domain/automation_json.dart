import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/verdicts.dart';

import 'automation.dart';
import 'automation_admission.dart';
import 'automation_check_verdict.dart';
import 'automation_run.dart';
import 'automation_steps.dart';
import 'automation_trigger.dart';
import 'automation_webhook.dart';
import 'github_trigger.dart';
import 'project_check.dart';
import 'scheduled_resume.dart';

// The wire shape of the automations domain's values. Every reader throws
// [FormatException] on a value out of shape.

String? _iso(DateTime? at) => at?.toUtc().toIso8601String();

DateTime _date(Object? value) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw const FormatException('expected a time');
  return parsed.toUtc();
}

DateTime? _optionalDate(Object? value) => value == null ? null : _date(value);

T _as<T>(Object? value) =>
    value is T ? value : throw FormatException('expected a $T');

List<String> _strings(Object? value) => value == null
    ? const []
    : [for (final item in _as<List<Object?>>(value)) _as<String>(item)];

Map<String, Object?> automationToJson(Automation a) => {
  'id': a.id,
  'repositoryId': a.repositoryId,
  'name': a.name,
  'cron': a.schedule.cron,
  'firesAt': _iso(a.schedule.firesAt),
  'everySeconds': a.schedule.everySeconds,
  'agentInstallationId': a.agentInstallationId,
  'prompt': a.prompt,
  'permissionMode': a.permissionMode?.canonical,
  'enabled': a.enabled,
  'armedAt': _iso(a.armedAt),
  'latePolicy': a.latePolicy.name,
  'stopAfterFailures': a.stopAfterFailures,
  'consecutiveFailures': a.consecutiveFailures,
  'disabledReason': a.disabledReason,
  'maxRuntimeSeconds': a.maxRuntime?.inSeconds,
  'triggerEvent': a.trigger?.kind.storedName,
  'eventAction': a.trigger?.action.storedName,
  'modelId': a.modelId,
  'worktree': a.worktree,
  'steps': a.steps.toJson(),
  if (a.webhook case final w?)
    'webhook': {
      'hookId': w.hookId,
      'requireSignature': w.requireSignature,
      // Where a reader that predates steps looks for them.
      'modelId': a.modelId,
      'worktree': a.worktree,
      'callsPerHour': w.callsPerHour,
    },
  if (a.github case final g?) 'github': g.toJson(),
  'runsPerHour': a.runsPerHour,
  'overlap': a.overlap.name,
  'queueLimit': a.queueLimit,
};

AutomationWebhook? _webhook(Object? json) {
  if (json == null) return null;
  final map = _as<Map<String, Object?>>(json);
  return AutomationWebhook(
    hookId: map['hookId'] as String? ?? '',
    requireSignature: map['requireSignature'] as bool? ?? true,
    callsPerHour: map['callsPerHour'] as int? ?? kDefaultWebhookCallsPerHour,
  );
}

Automation automationFromJson(Map<String, Object?> json) {
  final armedAt = _date(json['armedAt']);
  final seconds = json['maxRuntimeSeconds'] as int?;
  final hook = json['webhook'] is Map ? json['webhook']! as Map : const {};
  return Automation(
    id: _as<String>(json['id']),
    repositoryId: _as<String>(json['repositoryId']),
    name: _as<String>(json['name']),
    schedule:
        AutomationSchedule.fromRow(
          cron: json['cron'] as String?,
          firesAt: _optionalDate(json['firesAt']),
          everySeconds: json['everySeconds'] as int?,
        ) ??
        AutomationSchedule.once(armedAt),
    agentInstallationId: _as<String>(json['agentInstallationId']),
    prompt: _as<String>(json['prompt']),
    permissionMode: PermissionSelection.parse(
      json['permissionMode'] as String?,
    ),
    enabled: _as<bool>(json['enabled']),
    armedAt: armedAt,
    latePolicy: AutomationLatePolicy.fromName(json['latePolicy'] as String?),
    stopAfterFailures:
        json['stopAfterFailures'] as int? ?? kDefaultStopAfterFailures,
    consecutiveFailures: json['consecutiveFailures'] as int? ?? 0,
    disabledReason: json['disabledReason'] as String?,
    maxRuntime: seconds == null || seconds <= 0
        ? null
        : Duration(seconds: seconds),
    trigger: AutomationEventTrigger.fromRow(
      event: json['triggerEvent'] as String?,
      action: json['eventAction'] as String?,
    ),
    webhook: _webhook(json['webhook']),
    github: AutomationGithubTrigger.fromJson(json['github']),
    modelId: json['modelId'] as String? ?? hook['modelId'] as String?,
    worktree: json['worktree'] as bool? ?? hook['worktree'] as bool? ?? false,
    steps: json.containsKey('steps')
        ? AutomationSteps.fromJson(json['steps'])
        : AutomationSteps.unstated,
    runsPerHour: json['runsPerHour'] as int? ?? kDefaultRunsPerHour,
    overlap: AutomationOverlap.fromName(json['overlap'] as String?),
    queueLimit: json['queueLimit'] as int? ?? kDefaultQueueLimit,
  );
}

Map<String, Object?> automationRunToJson(AutomationRun r) => {
  'id': r.id,
  'automationId': r.automationId,
  'scheduledFor': _iso(r.scheduledFor),
  'firedAt': _iso(r.firedAt),
  'state': r.state.name,
  'reason': r.reason,
  'baseCheckpointId': r.baseCheckpointId,
  'sessionId': r.sessionId,
  'finishedAt': _iso(r.finishedAt),
  'commitsMade': r.commitsMade,
  'checksObservedAt': _iso(r.checksObservedAt),
  'origin': r.origin,
  'eventSessionId': r.eventSessionId,
  'startedBy': r.startedBy?.name,
  'prompt': ?r.prompt,
  if (r.stepResults.isNotEmpty)
    'stepResults': [for (final step in r.stepResults) step.toJson()],
  if (r.variables.isNotEmpty) 'variables': r.variables,
};

/// A string map, forgiving: a value that is not a string is left out.
Map<String, String> stringMapFrom(Object? json) => json is Map
    ? {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is String) key: value,
      }
    : const {};

AutomationRun automationRunFromJson(Map<String, Object?> json) => AutomationRun(
  id: _as<String>(json['id']),
  automationId: _as<String>(json['automationId']),
  scheduledFor: _date(json['scheduledFor']),
  firedAt: _date(json['firedAt']),
  state: AutomationRunState.fromName(json['state'] as String?),
  reason: json['reason'] as String? ?? '',
  baseCheckpointId: json['baseCheckpointId'] as String?,
  sessionId: json['sessionId'] as String?,
  finishedAt: _optionalDate(json['finishedAt']),
  commitsMade: json['commitsMade'] as int?,
  checksObservedAt: _optionalDate(json['checksObservedAt']),
  origin: _strings(json['origin']),
  eventSessionId: json['eventSessionId'] as String?,
  startedBy: AutomationRunCause.fromName(json['startedBy'] as String?),
  stepResults: AutomationStepResult.listFromJson(json['stepResults']),
  prompt: json['prompt'] as String?,
  variables: stringMapFrom(json['variables']),
);

Map<String, Object?> checkVerdictToJson(AutomationCheckVerdict v) => {
  'runId': v.runId,
  'ordinal': v.ordinal,
  'checkId': v.checkId,
  'name': v.name,
  'command': v.command,
  'verdict': v.verdict.name,
  'reason': v.reason,
  'verificationRunId': v.verificationRunId,
  'checkedAt': _iso(v.checkedAt),
};

AutomationCheckVerdict checkVerdictFromJson(Map<String, Object?> json) =>
    AutomationCheckVerdict(
      runId: _as<String>(json['runId']),
      ordinal: _as<int>(json['ordinal']),
      checkId: json['checkId'] as String?,
      name: _as<String>(json['name']),
      command: _strings(json['command']),
      verdict:
          VerificationVerdict.parse(json['verdict'] as String?) ??
          VerificationVerdict.inconclusive,
      reason: json['reason'] as String? ?? '',
      verificationRunId: json['verificationRunId'] as String?,
      checkedAt: _date(json['checkedAt']),
    );

Map<String, Object?> projectCheckToJson(ProjectCheck c) => {
  'id': c.id,
  'repositoryId': c.repositoryId,
  'name': c.name,
  'command': c.command,
  'createdAt': _iso(c.createdAt),
};

ProjectCheck projectCheckFromJson(Map<String, Object?> json) => ProjectCheck(
  id: _as<String>(json['id']),
  repositoryId: _as<String>(json['repositoryId']),
  name: _as<String>(json['name']),
  command: _strings(json['command']),
  createdAt: _date(json['createdAt']),
);

Map<String, Object?> scheduledResumeToJson(ScheduledResume r) => {
  'id': r.id,
  'sessionId': r.sessionId,
  'accountKey': r.accountKey,
  'accountEmail': r.accountEmail,
  'windowLabel': r.windowLabel,
  'resetsAt': _iso(r.resetsAt),
  'fireAt': _iso(r.fireAt),
  'message': r.message,
  'permissionMode': r.permissionMode,
  'notify': r.notify,
  'latePolicy': r.latePolicy.name,
  'state': r.state.name,
  'reason': r.reason,
  'attempts': r.attempts,
  'liveWhenScheduled': r.liveWhenScheduled,
  'scheduledBy': r.scheduledBy,
  'scheduledAt': _iso(r.scheduledAt),
  'finishedAt': _iso(r.finishedAt),
};

ScheduledResume scheduledResumeFromJson(Map<String, Object?> json) =>
    ScheduledResume(
      id: _as<String>(json['id']),
      sessionId: _as<String>(json['sessionId']),
      accountKey: json['accountKey'] as String? ?? '',
      accountEmail: json['accountEmail'] as String?,
      windowLabel: json['windowLabel'] as String?,
      resetsAt: _optionalDate(json['resetsAt']),
      fireAt: _date(json['fireAt']),
      message: json['message'] as String? ?? '',
      permissionMode: json['permissionMode'] as String?,
      notify: json['notify'] as bool? ?? false,
      latePolicy: ResumeLatePolicy.fromName(json['latePolicy'] as String?),
      state: ScheduledResumeState.fromName(json['state'] as String?),
      reason: json['reason'] as String? ?? '',
      attempts: json['attempts'] as int? ?? 0,
      liveWhenScheduled: json['liveWhenScheduled'] as bool? ?? false,
      scheduledBy: json['scheduledBy'] as String? ?? 'the user',
      scheduledAt: _date(json['scheduledAt']),
      finishedAt: _optionalDate(json['finishedAt']),
    );
