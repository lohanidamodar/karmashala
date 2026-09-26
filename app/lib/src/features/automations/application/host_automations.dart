import 'package:karmashala_host/lifecycle_client.dart'
    show AutomationCallKind, AutomationCallMessage;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import 'automation_check_runner.dart';
import 'automation_providers.dart';
import 'automation_runner.dart';
import 'host_automations_link.dart';
import 'scheduled_resume_runner.dart';

/// This app's half of the automations the server runs. The subscriber tells
/// it of every link.
final hostAutomationsLinkProvider = Provider<HostAutomationsLink>(
  (ref) => HostAutomationsLink(
    onCall: (call) => runForwardedAutomationCall(ref, call),
  ),
);

/// Does what the server forwarded because only this app can: start in a
/// checkout the server cannot launch into, resume a conversation, run checks
/// where the server cannot run commands.
Future<void> runForwardedAutomationCall(
  Ref ref,
  AutomationCallMessage call,
) async {
  // The server wrote the row before asking; its change may still be on the
  // data link, behind this call.
  Future<T> find<T>(T? Function() read, String what) async {
    final found = read();
    if (found != null) return found;
    await ref.read(dataClientProvider).resync(DataDomain.automations);
    return read() ?? (throw StateError('No $what ${call.id}.'));
  }

  final automations = ref.read(automationsDataProvider);
  switch (call.kind) {
    case AutomationCallKind.fireAutomation:
      final automation = await find(
        () => automations.getById(call.id),
        'automation',
      );
      final queuedId = call.queuedRunId;
      final queued = queuedId == null
          ? null
          : await find(() => automations.runById(queuedId), 'queued run');
      await ref
          .read(automationRunnerProvider)
          .fire(
            automation,
            call.scheduledFor ?? DateTime.now().toUtc(),
            note: call.note,
            queued: queued,
          );
    case AutomationCallKind.fireResume:
      final resumes = ref.read(resumesDataProvider);
      final resume = await find(
        () => resumes.getById(call.id),
        'scheduled resume',
      );
      await ref
          .read(scheduledResumeFiringProvider)
          .fire(resume, note: call.note);
    case AutomationCallKind.runChecks:
      final run = await find(() => automations.runById(call.id), 'run');
      ref.read(automationCheckRunnerProvider).start(run);
  }
}
