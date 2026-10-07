part of '../data_request.dart';

// Automations, their runs and checks, scheduled resumes, project checks.

DataRequest<Object?>? _automationsRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  AutomationsList.name => const AutomationsList(),
  AutomationSave.name => AutomationSave(
    args.value('automation', automationFromJson),
  ),
  AutomationSetEnabled.name => AutomationSetEnabled(
    args.string('id'),
    enabled: args.boolean('enabled'),
  ),
  AutomationDelete.name => AutomationDelete(args.string('id')),
  AutomationRecordOutcome.name => AutomationRecordOutcome(
    args.string('id'),
    failed: args.boolean('failed'),
  ),
  AutomationDisable.name => AutomationDisable(
    args.string('id'),
    args.string('reason'),
  ),
  AutomationRunPut.name => AutomationRunPut(
    args.value('run', automationRunFromJson),
  ),
  AutomationEventRunQueue.name => AutomationEventRunQueue(
    args.value('run', automationRunFromJson),
  ),
  AutomationRunCheckAdd.name => AutomationRunCheckAdd(
    args.value('verdict', checkVerdictFromJson),
  ),
  AutomationRunChecksObserved.name => AutomationRunChecksObserved(
    args.string('runId'),
    args.date('at'),
  ),
  AutomationOriginMark.name => AutomationOriginMark(
    args.string('sessionId'),
    args.strings('origin'),
  ),
  AutomationOriginClear.name => AutomationOriginClear(args.string('sessionId')),
  ProjectCheckAdd.name => ProjectCheckAdd(
    args.value('check', projectCheckFromJson),
  ),
  ProjectCheckDelete.name => ProjectCheckDelete(args.string('id')),
  ProjectVerificationSet.name => ProjectVerificationSet(
    args.string('repositoryId'),
    enabled: args.boolean('enabled'),
  ),
  ResumeSchedule.name => ResumeSchedule(
    args.value('resume', scheduledResumeFromJson),
  ),
  ResumeUpdate.name => ResumeUpdate(
    args.value('resume', scheduledResumeFromJson),
  ),
  ResumeTransition.name => ResumeTransition(
    args.string('id'),
    from: _resumeState(args, 'from'),
    to: _resumeState(args, 'to'),
  ),
  ResumeDelete.name => ResumeDelete(args.string('id')),
  AutomationRunsPage.name => AutomationRunsPage(
    before: args.optionalString('before') == null ? null : args.date('before'),
    limit: args.optionalInt('limit') ?? kRunsPageSize,
    automationId: args.optionalString('automationId'),
  ),
  AutomationRunNow.name => AutomationRunNow(args.string('id')),
  AutomationRunCancel.name => AutomationRunCancel(args.string('runId')),
  _ => null,
};

ScheduledResumeState _resumeState(_Arguments args, String key) {
  final state = ScheduledResumeState.fromName(args.string(key));
  if (state == ScheduledResumeState.unrecognised) {
    throw DataRefused.invalid('${args.kind}: "$key" is not a resume state');
  }
  return state;
}

/// A request of the automations domain.
sealed class AutomationsRequest<R> extends DataRequest<R> {
  const AutomationsRequest();
}

/// How many runs a page holds unless asked otherwise.
const int kRunsPageSize = 50;

/// One page of runs, newest first, and each one's checks.
class AutomationRunsPageResult {
  const AutomationRunsPageResult({
    required this.runs,
    required this.checks,
    required this.more,
  });

  final List<AutomationRun> runs;
  final Map<String, List<AutomationCheckVerdict>> checks;

  /// Whether older runs than these are kept.
  final bool more;

  Map<String, Object?> toJson() => {
    'runs': [for (final run in runs) automationRunToJson(run)],
    'checks': {
      for (final entry in checks.entries)
        entry.key: [for (final v in entry.value) checkVerdictToJson(v)],
    },
    'more': more,
  };

  static AutomationRunsPageResult fromJson(Map<String, Object?> json) =>
      AutomationRunsPageResult(
        runs: [
          for (final run in json['runs']! as List<Object?>)
            automationRunFromJson(run! as Map<String, Object?>),
        ],
        checks: {
          for (final entry
              in (json['checks'] as Map<String, Object?>? ?? const {}).entries)
            entry.key: [
              for (final v in entry.value! as List<Object?>)
                checkVerdictFromJson(v! as Map<String, Object?>),
            ],
        },
        more: json['more'] as bool? ?? false,
      );
}

/// Runs fired before [before] (all, when null), newest first, at most
/// [limit] — of [automationId] only when one is named. What the Runs tab
/// pages through past the copy a client keeps.
final class AutomationRunsPage
    extends AutomationsRequest<AutomationRunsPageResult> {
  const AutomationRunsPage({
    this.before,
    this.limit = kRunsPageSize,
    this.automationId,
  });

  static const String name = 'automationRuns.page';

  final DateTime? before;
  final int limit;
  final String? automationId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    if (before case final before?) 'before': before.toUtc().toIso8601String(),
    'limit': limit,
    'automationId': ?automationId,
  };

  @override
  Object? resultToJson(AutomationRunsPageResult result) => result.toJson();

  @override
  AutomationRunsPageResult resultFromJson(Object? json) => _decode(
    kind,
    () => AutomationRunsPageResult.fromJson(_object(json, kind)),
  );
}

/// Automation work that starts or stops an agent; answered when done.
sealed class AutomationWorkRequest<R> extends DataRequest<R> {
  const AutomationWorkRequest();

  @override
  Object? resultToJson(R result) =>
      automationRunToJson(result as AutomationRun);

  @override
  R resultFromJson(Object? json) =>
      _decode(kind, () => automationRunFromJson(_object(json, kind))) as R;
}

/// Starts automation [id] now, as a person's act: the same gate, checkpoint
/// and launch a scheduled run takes, recorded as started by Run now. Answers
/// the run as it was left — running, waiting for its checkout, or failed with
/// the reason.
final class AutomationRunNow extends AutomationWorkRequest<AutomationRun> {
  const AutomationRunNow(this.id);

  static const String name = 'automations.runNow';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Stops run [runId]: a waiting one is let go, a running one's session is
/// ended. Answers the run as it now stands.
final class AutomationRunCancel extends AutomationWorkRequest<AutomationRun> {
  const AutomationRunCancel(this.runId);

  static const String name = 'automationRuns.cancel';

  final String runId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'runId': runId};
}

/// The whole domain a client copies ([AutomationsSnapshot]).
final class AutomationsList extends AutomationsRequest<AutomationsSnapshot> {
  const AutomationsList();

  static const String name = 'automations.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(AutomationsSnapshot result) => result.toJson();

  @override
  AutomationsSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => AutomationsSnapshot.fromJson(_object(json, kind)));
}

/// Arms or rewrites an automation — a person's act. Refused for a blank name
/// and for a checkout that does not exist; the server re-arms its scheduler.
final class AutomationSave extends _AutomationAnswer {
  const AutomationSave(this.automation);

  static const String name = 'automations.save';

  final Automation automation;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'automation': automationToJson(automation),
  };
}

/// Pauses or resumes an automation, leaving its arming alone.
final class AutomationSetEnabled extends _AutomationAnswer {
  const AutomationSetEnabled(this.id, {required this.enabled});

  static const String name = 'automations.setEnabled';

  final String id;
  final bool enabled;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'enabled': enabled};
}

/// Deletes an automation and, with it, its runs and their checks.
final class AutomationDelete extends _AutomationsAck {
  const AutomationDelete(this.id);

  static const String name = 'automations.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Counts one run against the automation's failure budget (a success clears
/// it and the reason it was disabled).
final class AutomationRecordOutcome extends _AutomationAnswer {
  const AutomationRecordOutcome(this.id, {required this.failed});

  static const String name = 'automations.recordOutcome';

  final String id;
  final bool failed;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'failed': failed};
}

/// Disables an automation nobody asked to stop, saying why.
final class AutomationDisable extends _AutomationAnswer {
  const AutomationDisable(this.id, this.reason);

  static const String name = 'automations.disable';

  final String id;
  final String reason;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'reason': reason};
}

/// Records a run a client fired or settled — new, or the same id rewritten.
/// Refused for an automation that does not exist.
final class AutomationRunPut extends _RunAnswer {
  const AutomationRunPut(this.run);

  static const String name = 'automationRuns.put';

  final AutomationRun run;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'run': automationRunToJson(run)};
}

/// An event rule's run, queued behind whatever holds its checkout (or
/// `missed` when the rule already has one live) — the server starts it when
/// the checkout comes free. Answers the row as written.
final class AutomationEventRunQueue extends _RunAnswer {
  const AutomationEventRunQueue(this.run);

  static const String name = 'automationRuns.queueEvent';

  final AutomationRun run;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'run': automationRunToJson(run)};
}

/// One project check's verdict for a run.
final class AutomationRunCheckAdd extends _AutomationsAck {
  const AutomationRunCheckAdd(this.verdict);

  static const String name = 'automationRuns.addCheck';

  final AutomationCheckVerdict verdict;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'verdict': checkVerdictToJson(verdict),
  };
}

/// Run [runId]'s checks were looked at, whatever they said.
final class AutomationRunChecksObserved extends _RunAnswer {
  const AutomationRunChecksObserved(this.runId, this.at);

  static const String name = 'automationRuns.checksObserved';

  final String runId;
  final DateTime at;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'runId': runId,
    'at': at.toUtc().toIso8601String(),
  };
}

/// An automation's message is going into [sessionId]: the turn it causes
/// carries [origin]. The server stamps the time.
final class AutomationOriginMark extends _AutomationsAck {
  const AutomationOriginMark(this.sessionId, this.origin);

  static const String name = 'automationOrigins.mark';

  final String sessionId;
  final List<String> origin;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'origin': origin,
  };
}

/// The chain a message left on [sessionId] is spent.
final class AutomationOriginClear extends _AutomationsAck {
  const AutomationOriginClear(this.sessionId);

  static const String name = 'automationOrigins.clear';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};
}

/// Adds a project check; the server stamps it. Refused for a blank name or
/// command and for a checkout that does not exist.
final class ProjectCheckAdd extends AutomationsRequest<ProjectCheck> {
  const ProjectCheckAdd(this.check);

  static const String name = 'projectChecks.add';

  final ProjectCheck check;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'check': projectCheckToJson(check),
  };

  @override
  Object? resultToJson(ProjectCheck result) => projectCheckToJson(result);

  @override
  ProjectCheck resultFromJson(Object? json) =>
      _decode(kind, () => projectCheckFromJson(_object(json, kind)));
}

final class ProjectCheckDelete extends _AutomationsAck {
  const ProjectCheckDelete(this.id);

  static const String name = 'projectChecks.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Switches a checkout's verification — what the unattended gate refuses
/// without.
final class ProjectVerificationSet extends _AutomationsAck {
  const ProjectVerificationSet(this.repositoryId, {required this.enabled});

  static const String name = 'projectChecks.setVerification';

  final String repositoryId;
  final bool enabled;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'repositoryId': repositoryId,
    'enabled': enabled,
  };
}

/// Arms [resume], ending whatever was live for its session. Refused for a
/// session that does not exist.
final class ResumeSchedule extends _ResumeAnswer {
  const ResumeSchedule(this.resume);

  static const String name = 'resumes.schedule';

  final ScheduledResume resume;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'resume': scheduledResumeToJson(resume),
  };
}

/// Writes what moves on an armed resume after arming (its state, reason,
/// moment, attempts, account); what the person chose never changes.
final class ResumeUpdate extends _ResumeAnswer {
  const ResumeUpdate(this.resume);

  static const String name = 'resumes.update';

  final ScheduledResume resume;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'resume': scheduledResumeToJson(resume),
  };
}

/// Moves resume [id] from [from] to [to]; answers false when it was not in
/// [from] — the guard that keeps one row from firing twice.
final class ResumeTransition extends AutomationsRequest<bool> {
  const ResumeTransition(this.id, {required this.from, required this.to});

  static const String name = 'resumes.transition';

  final String id;
  final ScheduledResumeState from;
  final ScheduledResumeState to;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'from': from.name,
    'to': to.name,
  };

  @override
  Object? resultToJson(bool result) => result;

  @override
  bool resultFromJson(Object? json) => json is bool ? json : _badAnswer(kind);
}

final class ResumeDelete extends _AutomationsAck {
  const ResumeDelete(this.id);

  static const String name = 'resumes.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

sealed class _AutomationsAck extends AutomationsRequest<DataAck> {
  const _AutomationsAck();

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

sealed class _AutomationAnswer extends AutomationsRequest<Automation> {
  const _AutomationAnswer();

  @override
  Object? resultToJson(Automation result) => automationToJson(result);

  @override
  Automation resultFromJson(Object? json) =>
      _decode(kind, () => automationFromJson(_object(json, kind)));
}

sealed class _RunAnswer extends AutomationsRequest<AutomationRun> {
  const _RunAnswer();

  @override
  Object? resultToJson(AutomationRun result) => automationRunToJson(result);

  @override
  AutomationRun resultFromJson(Object? json) =>
      _decode(kind, () => automationRunFromJson(_object(json, kind)));
}

sealed class _ResumeAnswer extends AutomationsRequest<ScheduledResume> {
  const _ResumeAnswer();

  @override
  Object? resultToJson(ScheduledResume result) => scheduledResumeToJson(result);

  @override
  ScheduledResume resultFromJson(Object? json) =>
      _decode(kind, () => scheduledResumeFromJson(_object(json, kind)));
}
