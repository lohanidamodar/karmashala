import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_outcome_writer.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_hook_spool_drainer.dart';
import 'agent_status_providers.dart';

/// Drains the spool directories a file-reporting agent writes into, applying
/// each payload exactly as the HTTP route does. An empty list starts no timer.
final agentHookSpoolDrainerProvider = Provider<AgentHookSpoolDrainer>((ref) {
  final logger = AppLogger.named('agent-hooks');
  final drainer = AgentHookSpoolDrainer(
    onEvent: (event) => applyAgentHookCallback(
      ref.container,
      agentId: event.agentId,
      event: event.event,
      body: event.body,
      observedAt: event.firedAt,
      logger: logger,
    ),
  );
  ref.onDispose(drainer.dispose);
  return drainer;
});

/// Everything one hook callback does, whichever transport carried it — a second
/// copy of these steps is how the two would come to disagree. **Never throws.**
AgentStatusReport applyAgentHookCallback(
  ProviderContainer container, {
  required String? agentId,
  required String? event,
  required String body,
  DateTime? observedAt,
  AppLogger? logger,
}) {
  final report = container
      .read(agentHookReceiverProvider)
      .handle(
        agentId: agentId,
        event: event,
        body: body,
        observedAt: observedAt,
      );
  // A callback naming a session we have no row for may be one the user started
  // by hand in one of our own panes. Synchronous and O(1) once decided.
  try {
    container
        .read(sessionAdoptionServiceProvider)
        .onHookPayload(
          agentId: report.agentId,
          sessionId: report.sessionId,
          body: body,
        );
  } on Object catch (error) {
    logger?.warning('Session adoption from a hook failed: $error');
  }
  // The status pipeline's *primary* input: a hook is authoritative and already
  // in memory, so folding it in here beats a poll five seconds later.
  try {
    reportAgentHook(
      container,
      agentId: report.agentId,
      sessionId: report.sessionId,
    );
  } on Object catch (error) {
    logger?.warning('Applying a hook report to the registry failed: $error');
  }
  // The durable half, and the only thing that writes an *ending* onto a session
  // row. Almost every callback carries none, so this is usually a null check.
  try {
    container
        .read(sessionOutcomeWriterProvider)
        .record(
          agentSessionId: report.sessionId,
          ending: report.ending,
        );
  } on Object catch (error) {
    logger?.warning('Recording a session ending from a hook failed: $error');
  }
  return report;
}
