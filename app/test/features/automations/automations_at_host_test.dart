import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_check_runner.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/host_automations.dart';
import 'package:karmashala/src/features/automations/application/host_automations_link.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show ChecksRanMessage, ChecksRunOutcome;
import 'package:karmashala_verification/verification.dart';

import 'scheduled_resume_harness.dart';

/// Stands in for the link to the server: answers a check request as it would.
class _RecordingLink extends HostAutomationsLink {
  _RecordingLink() : super(onCall: (_) async {});

  final asked = <String>[];
  ChecksRanMessage Function(String sessionId)? answer;

  @override
  Future<ChecksRanMessage>? runChecks(String sessionId) {
    asked.add(sessionId);
    final reply = answer;
    return reply == null ? null : Future.value(reply(sessionId));
  }
}

/// The server runs automations: this app's writes reach it through the data
/// API (which wakes its scheduler), and it is asked to run a session's checks.
void main() {
  late ResumeHarness h;
  late _RecordingLink link;

  setUp(() async {
    link = _RecordingLink();
    h = await ResumeHarness.create(
      extra: [hostAutomationsLinkProvider.overrideWithValue(link)],
    );
    h.addSession();
    h.server.automationRows.insert(
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

  test('an edit made here is the server\'s at once, and wakes it', () async {
    h.container
        .read(automationControllerProvider)
        .setEnabled('auto1', enabled: false);
    // The copy has it now; the server once the write lands.
    expect(h.container.read(automationsProvider).single.enabled, isFalse);
    await h.container.read(dataClientProvider).settled();
    expect(h.server.automationRows.getById('auto1')!.enabled, isFalse);
    expect(h.server.automationRows.written, 1);
  });

  test('a row the server wrote reaches the page', () async {
    h.server.automationRows.disable('auto1', 'broken');
    await h.settle();
    final shown = h.container.read(automationsProvider).single;
    expect((shown.enabled, shown.disabledReason), (false, 'broken'));
  });

  test(
    'a session\'s checks run at the server, and its run is the answer',
    () async {
      h.server.verificationRows.put(
        VerificationRun(
          id: 'vr-1',
          title: 'Project checks · Work',
          target: const VerificationTarget.change(),
          sessionId: 's1',
          producedBySessionId: kAppVerifierId,
          startedAt: h.now,
          finishedAt: h.now,
          verdict: VerificationVerdict.pass,
          artifactDirectory: '/tmp/vr-1',
        ),
      );
      link.answer = (sessionId) => const ChecksRanMessage(
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
    },
  );

  test('a checkout with no checks answers nothing', () async {
    link.answer = (_) =>
        const ChecksRanMessage(requestId: 1, outcome: ChecksRunOutcome.none);
    final result = await h.container
        .read(runningSessionChecksProvider.notifier)
        .run('s1');
    expect(result, isNull);
  });
}
