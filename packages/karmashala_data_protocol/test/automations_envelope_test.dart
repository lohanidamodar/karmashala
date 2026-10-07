import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// The automations domain through the envelope as JSON text: every request,
/// its answer, and every change.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 3);
  final automation = Automation(
    id: 'auto1',
    repositoryId: 'r1',
    name: 'Nightly',
    schedule: AutomationSchedule.every(const Duration(minutes: 90)),
    agentInstallationId: 'a1',
    prompt: 'tidy',
    permissionMode: PermissionSelection.parse('mode=auto'),
    enabled: true,
    armedAt: t0,
    latePolicy: AutomationLatePolicy.skip,
    maxRuntime: const Duration(minutes: 20),
    trigger: const AutomationEventTrigger(
      kind: AutomationEventKind.turnFinished,
      action: AutomationEventAction.messageSession,
    ),
  );
  final run = AutomationRun(
    id: 'run1',
    automationId: 'auto1',
    scheduledFor: t0,
    firedAt: t0,
    state: AutomationRunState.queued,
    reason: 'waiting',
    origin: const ['auto0', 'auto1'],
    eventSessionId: 's1',
    checksObservedAt: t0,
  );
  final verdict = AutomationCheckVerdict(
    runId: 'run1',
    ordinal: 1,
    checkId: 'c1',
    name: 'tests',
    command: const ['make', 'test'],
    verdict: VerificationVerdict.fail,
    reason: 'exit 2',
    verificationRunId: 'v1',
    checkedAt: t0,
  );
  final check = ProjectCheck(
    id: 'c1',
    repositoryId: 'r1',
    name: 'tests',
    command: const ['make', 'test'],
    createdAt: t0,
  );
  final resume = ScheduledResume(
    id: 'res1',
    sessionId: 's1',
    fireAt: t0,
    state: ScheduledResumeState.queued,
    scheduledAt: t0,
    windowLabel: '5h',
    resetsAt: t0,
    notify: true,
    latePolicy: ResumeLatePolicy.resume,
    attempts: 2,
    liveWhenScheduled: true,
  );

  R roundTrip<R>(DataRequest<R> request, R result) {
    final asked = jsonDecode(jsonEncode(DataEnvelope.request(1, request)));
    final read = DataEnvelope.readRequest(
      (asked as Map).cast<String, Object?>(),
    );
    expect(read.request!.kind, request.kind);
    expect(
      jsonEncode(read.request!.argumentsToJson()),
      jsonEncode(request.argumentsToJson()),
    );
    final answered = jsonDecode(
      jsonEncode(DataEnvelope.answer(1, request, DataReply(result, 3))),
    );
    return DataEnvelope.readAnswer(
      (answered as Map).cast<String, Object?>(),
      request,
    ).value;
  }

  test('a page of runs carries its checks and whether there are more', () {
    final page = roundTrip(
      AutomationRunsPage(before: t0, limit: 10, automationId: 'auto1'),
      AutomationRunsPageResult(
        runs: [run],
        checks: {
          'run1': [verdict],
        },
        more: true,
      ),
    );
    expect(page.runs.single.id, 'run1');
    expect(page.checks['run1']!.single.verdict, VerificationVerdict.fail);
    expect(page.more, isTrue);
  });

  test('Run now and Cancel answer the run as it was left', () {
    final started = roundTrip(
      const AutomationRunNow('auto1'),
      run.copyWith(state: AutomationRunState.running),
    );
    expect(started.state, AutomationRunState.running);
    final cancelled = roundTrip(
      const AutomationRunCancel('run1'),
      run.copyWith(state: AutomationRunState.failed, reason: 'Cancelled.'),
    );
    expect(cancelled.reason, 'Cancelled.');
  });

  test('every request and its answer', () {
    final snapshot = roundTrip(
      const AutomationsList(),
      AutomationsSnapshot(
        automations: [automation],
        runs: [run],
        checks: {
          'run1': [verdict],
        },
        origins: const {
          's1': ['auto1'],
        },
        projectChecks: [check],
        verified: const {'r1'},
        resumes: [resume],
      ),
    );
    expect(
      jsonEncode(automationToJson(snapshot.automations.single)),
      jsonEncode(automationToJson(automation)),
    );
    expect(
      jsonEncode(automationRunToJson(snapshot.runs.single)),
      jsonEncode(automationRunToJson(run)),
    );
    expect(snapshot.checks['run1']!.single.verdict, VerificationVerdict.fail);
    expect(snapshot.origins['s1'], ['auto1']);
    expect(snapshot.projectChecks.single, check);
    expect(snapshot.verified, {'r1'});
    expect(
      jsonEncode(scheduledResumeToJson(snapshot.resumes.single)),
      jsonEncode(scheduledResumeToJson(resume)),
    );

    expect(roundTrip(AutomationSave(automation), automation).id, 'auto1');
    roundTrip(const AutomationSetEnabled('auto1', enabled: false), automation);
    roundTrip(const AutomationDelete('auto1'), const DataAck());
    roundTrip(const AutomationRecordOutcome('auto1', failed: true), automation);
    roundTrip(const AutomationDisable('auto1', 'why'), automation);
    expect(roundTrip(AutomationRunPut(run), run).origin, run.origin);
    roundTrip(AutomationEventRunQueue(run), run);
    roundTrip(AutomationRunCheckAdd(verdict), const DataAck());
    roundTrip(AutomationRunChecksObserved('run1', t0), run);
    roundTrip(const AutomationOriginMark('s1', ['a']), const DataAck());
    roundTrip(const AutomationOriginClear('s1'), const DataAck());
    expect(roundTrip(ProjectCheckAdd(check), check), check);
    roundTrip(const ProjectCheckDelete('c1'), const DataAck());
    roundTrip(
      const ProjectVerificationSet('r1', enabled: true),
      const DataAck(),
    );
    roundTrip(ResumeSchedule(resume), resume);
    roundTrip(ResumeUpdate(resume), resume);
    expect(
      roundTrip(
        const ResumeTransition(
          'res1',
          from: ScheduledResumeState.pending,
          to: ScheduledResumeState.firing,
        ),
        true,
      ),
      isTrue,
    );
    roundTrip(const ResumeDelete('res1'), const DataAck());
  });

  test('a transition to a state nobody knows is refused', () {
    final read = DataEnvelope.readRequest({
      'id': 1,
      'kind': ResumeTransition.name,
      'arguments': {'id': 'r', 'from': 'pending', 'to': 'teleported'},
    });
    expect(read.refusal!.code, DataRefusalCode.invalid);
  });

  test('every change', () {
    final changes = <DataChange>[
      AutomationChanged(automation),
      const AutomationRemoved('auto1'),
      AutomationRunChanged(run),
      AutomationRunCheckAdded(verdict),
      const AutomationOriginChanged('s1', ['auto1']),
      ProjectCheckChanged(check),
      const ProjectCheckRemoved('c1'),
      const ProjectVerificationChanged('r1', enabled: false),
      ResumeChanged(resume),
      const ResumeRemoved('res1'),
    ];
    final json = jsonDecode(jsonEncode(DataChanges(4, changes).toJson()));
    final read = DataChanges.fromJson((json as Map).cast<String, Object?>());
    expect(
      [for (final c in read.changes) jsonEncode(c.toJson())],
      [for (final c in changes) jsonEncode(c.toJson())],
    );
  });
}
