import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/automation_check_runner.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_scheduler.dart';
import 'package:karmashala/src/features/automations/application/host_automations.dart';
import 'package:karmashala/src/features/automations/application/host_automations_link.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show ChecksRanMessage, ChecksRunOutcome;
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';

import 'scheduled_resume_harness.dart';

/// Stands in for the link to the host: counts what this app told it, and
/// answers a check request as the host would.
class _RecordingLink extends HostAutomationsLink {
  _RecordingLink() : super(onCall: (_) async {}, onHostChanged: () {});

  var notified = 0;
  final asked = <String>[];
  ChecksRanMessage Function(String sessionId)? answer;

  @override
  void notifyChanged() => notified++;

  @override
  Future<ChecksRanMessage>? runChecks(String sessionId) {
    asked.add(sessionId);
    final reply = answer;
    return reply == null ? null : Future.value(reply(sessionId));
  }
}

class _NoFiring implements AutomationFiring {
  final fired = <String>[];
  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async => fired.add(automation.id);
}

/// Where the session host runs automations, this app fires none, hands every
/// write and event run to it, and asks it to run a session's checks.
void main() {
  late ResumeHarness h;
  late _RecordingLink link;
  late _NoFiring firing;

  setUp(() async {
    link = _RecordingLink();
    firing = _NoFiring();
    h = await ResumeHarness.create(
      extra: [
        automationsAtHostProvider.overrideWithValue(true),
        hostAutomationsLinkProvider.overrideWithValue(link),
        automationFiringProvider.overrideWithValue(firing),
      ],
    );
    h.addSession();
    AutomationDao(h.db).insert(
      Automation(
        id: 'auto1',
        repositoryId: 'r1',
        name: 'Nightly',
        schedule: const AutomationSchedule.cron('* * * * *'),
        agentInstallationId: 'a1',
        prompt: 'Fix it.',
        permissionMode: null,
        enabled: true,
        armedAt: h.now.subtract(const Duration(minutes: 3)),
      ),
    );
  });
  tearDown(() => h.dispose());

  test('a due automation is the host\'s to fire, not this app\'s', () async {
    final scheduler = h.scheduler();
    await h.settle();
    await scheduler.reconcile();
    await h.settle();
    expect(firing.fired, isEmpty);
    expect(AutomationDao(h.db).runsFor('auto1'), isEmpty);
    // Asked instead: the host re-reads and re-arms.
    expect(link.notified, greaterThan(0));
  });

  test('an event run is queued in the store for the host to start', () async {
    final scheduler = h.scheduler();
    final automation = AutomationDao(h.db).getById('auto1')!;
    final before = link.notified;
    await scheduler.startEventRun(
      automation,
      AutomationRun(
        id: 'event-run',
        automationId: 'auto1',
        scheduledFor: h.now,
        firedAt: h.now,
        state: AutomationRunState.running,
        reason: 'Because "Work" finishes a turn.',
        eventSessionId: 's1',
      ),
    );
    final run = AutomationDao(h.db).runById('event-run')!;
    expect(run.state, AutomationRunState.queued);
    expect(firing.fired, isEmpty);
    expect(link.notified, greaterThan(before));
  });

  test('an edit made here is told to the host', () {
    final before = link.notified;
    h.container
        .read(automationControllerProvider)
        .setEnabled('auto1', enabled: false);
    expect(link.notified, before + 1);
  });

  test('a session\'s checks run at the host, and the host\'s run is the '
      'answer', () async {
    final run = VerificationRun(
      id: 'vr-1',
      title: 'Project checks · Work',
      target: const VerificationTarget.change(),
      sessionId: 's1',
      producedBySessionId: kAppVerifierId,
      startedAt: h.now,
      finishedAt: h.now,
      verdict: VerificationVerdict.pass,
      artifactDirectory: '/tmp/vr-1',
    );
    VerificationDao(h.db).insertRun(run);
    link.answer = (sessionId) => ChecksRanMessage(
      requestId: 1,
      outcome: ChecksRunOutcome.ran,
      verificationRunId: 'vr-1',
    );
    final result = await h.container
        .read(runningSessionChecksProvider.notifier)
        .run('s1');
    expect(link.asked, ['s1']);
    expect(result!.run.id, 'vr-1');
    expect(result.run.attribution, VerdictAttribution.app);
  });

  test('a checkout with no checks answers nothing, as the app would', () async {
    link.answer = (_) =>
        const ChecksRanMessage(requestId: 1, outcome: ChecksRunOutcome.none);
    final result = await h.container
        .read(runningSessionChecksProvider.notifier)
        .run('s1');
    expect(result, isNull);
  });
}
