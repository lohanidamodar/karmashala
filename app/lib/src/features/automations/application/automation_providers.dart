import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart'
    show compareRunsNewestFirst;
import 'package:karmashala_automations/runs.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart' show capabilitiesProvider;
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../data/automations_data.dart';

export '../data/automations_data.dart'
    show
        automationsDataProvider,
        automationsRevisionProvider,
        projectChecksDataProvider,
        resumesDataProvider;

final automationsProvider = Provider<List<Automation>>((ref) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(automationsDataProvider).getAll();
});

/// Whether the server this app talks to takes webhook calls.
final webhooksOfferedProvider = Provider<bool>(
  (ref) => ref.watch(capabilitiesProvider).serverOffers('automations.webhooks'),
);

/// How a session came to be when an automation started it: "from webhook
/// triage-issue", "from automation Nightly sweep" — or null for any other.
final sessionAutomationOriginProvider = Provider.family<String?, String>((
  ref,
  sessionId,
) {
  ref.watch(automationsRevisionProvider);
  final data = ref.watch(automationsDataProvider);
  final run = data.runForSession(sessionId);
  if (run == null) return null;
  final automation = data.getById(run.automationId);
  if (automation == null) return null;
  return automation.isWebhook
      ? 'from webhook ${automation.name}'
      : 'from automation ${automation.name}';
});

/// Every run the client holds, across every automation, newest first.
final allAutomationRunsProvider = Provider<List<AutomationRun>>((ref) {
  ref.watch(automationsRevisionProvider);
  return [...ref.watch(automationsDataProvider).runRows]
    ..sort(compareRunsNewestFirst);
});

final automationRunsProvider = Provider.family<List<AutomationRun>, String>((
  ref,
  automationId,
) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(automationsDataProvider).runsFor(automationId);
});

/// What one occurrence's project checks said, in the order they ran.
final automationRunChecksProvider =
    Provider.family<List<AutomationCheckVerdict>, String>((ref, runId) {
      ref.watch(automationsRevisionProvider);
      return ref.watch(automationsDataProvider).checksFor(runId);
    });

final projectChecksProvider = Provider.family<List<ProjectCheck>, String>((
  ref,
  repositoryId,
) {
  ref.watch(automationsRevisionProvider);
  return ref.watch(projectChecksDataProvider).forRepository(repositoryId);
});

final projectVerificationEnabledProvider = Provider.family<bool, String>((
  ref,
  repositoryId,
) {
  ref.watch(automationsRevisionProvider);
  return ref
      .watch(projectChecksDataProvider)
      .isVerificationEnabled(repositoryId);
});

/// Writes an automation or a checkout's verification through the server.
/// Arming goes through here and nowhere else — no MCP tool reaches it.
class AutomationController {
  AutomationController(this._ref);

  final Ref _ref;

  String newId() => _ref.read(idGeneratorProvider).newId();
  DateTime now() => _ref.read(clockProvider).nowUtc();

  void save(Automation automation) =>
      _ref.read(automationsDataProvider).save(automation);

  void setEnabled(String id, {required bool enabled}) =>
      _ref.read(automationsDataProvider).setEnabled(id, enabled: enabled);

  void delete(String id) => _ref.read(automationsDataProvider).delete(id);

  void setVerificationEnabled(String repositoryId, {required bool enabled}) =>
      _ref
          .read(projectChecksDataProvider)
          .setVerification(repositoryId, enabled: enabled);

  void addCheck(String repositoryId, String name, List<String> command) => _ref
      .read(projectChecksDataProvider)
      .add(
        ProjectCheck(
          id: newId(),
          repositoryId: repositoryId,
          name: name.trim(),
          command: command,
          createdAt: now(),
        ),
      );

  void removeCheck(String id) =>
      _ref.read(projectChecksDataProvider).remove(id);
}

final automationControllerProvider = Provider<AutomationController>(
  AutomationController.new,
);
