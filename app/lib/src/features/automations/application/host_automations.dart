import 'package:karmashala_host/lifecycle_client.dart'
    show AutomationCallKind, AutomationCallMessage;
import 'package:riverpod/riverpod.dart';

import '../../agents/application/host_hook_endpoint.dart';
import '../../sessions/application/session_signals.dart';
import '../../verification/application/verification_providers.dart';
import 'automation_check_runner.dart';
import 'automation_providers.dart';
import 'automation_runner.dart';
import 'host_automations_link.dart';
import 'scheduled_resume_providers.dart';
import 'scheduled_resume_runner.dart';

/// Whether this machine's session host runs automations and checks: whenever
/// it serves hooks, tools and phones. This app then fires none of its own.
final automationsAtHostProvider = Provider<bool>(
  (ref) => ref.watch(agentHooksAtHostProvider),
);

/// This app's half of the automations the host runs. The subscriber tells it
/// of every link.
final hostAutomationsLinkProvider = Provider<HostAutomationsLink>(
  (ref) => HostAutomationsLink(
    onCall: (call) => runForwardedAutomationCall(ref, call),
    onHostChanged: () {
      ref.read(automationsRevisionProvider.notifier).bumpFromHost();
      ref.read(verificationChangesProvider).bump();
      // A run the host started is a session row this app has not seen.
      ref.publishSessionChange(
        const SessionChange(
          kinds: {SessionChangeKind.membership, SessionChangeKind.status},
        ),
      );
    },
  ),
);

/// Does what the host forwarded because only this app can: start in a
/// checkout the host cannot launch into, resume a conversation, run checks
/// where the host cannot run commands.
Future<void> runForwardedAutomationCall(
  Ref ref,
  AutomationCallMessage call,
) async {
  switch (call.kind) {
    case AutomationCallKind.fireAutomation:
      final dao = ref.read(automationDaoProvider);
      final automation = dao.getById(call.id);
      if (automation == null) {
        throw StateError('No automation ${call.id}.');
      }
      final queuedId = call.queuedRunId;
      await ref
          .read(automationRunnerProvider)
          .fire(
            automation,
            call.scheduledFor ?? DateTime.now().toUtc(),
            note: call.note,
            queued: queuedId == null ? null : dao.runById(queuedId),
          );
    case AutomationCallKind.fireResume:
      final resume = ref.read(scheduledResumeDaoProvider).getById(call.id);
      if (resume == null) throw StateError('No scheduled resume ${call.id}.');
      await ref
          .read(scheduledResumeFiringProvider)
          .fire(resume, note: call.note);
    case AutomationCallKind.runChecks:
      final run = ref.read(automationDaoProvider).runById(call.id);
      if (run == null) throw StateError('No automation run ${call.id}.');
      ref.read(automationCheckRunnerProvider).start(run);
  }
}
