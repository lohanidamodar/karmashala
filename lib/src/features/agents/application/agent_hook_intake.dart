import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_outcome_writer.dart';
import '../domain/agent_status.dart';
import 'agent_hook_spool_drainer.dart';
import 'agent_status_providers.dart';

/// Drains the spool directories a file-reporting agent writes its hook payloads
/// into, and applies each payload exactly as the HTTP route applies a callback.
///
/// Started by the lifecycle owner once the install sweep has said which
/// directories exist — and on a machine with no such environment that list is
/// empty, so the timer never starts. See [AgentHookSpoolDrainer.watch].
///
/// It lives here rather than beside the other hook providers because it is the
/// spool's half of [applyAgentHookCallback], and putting it there made
/// `agent_status_providers.dart` and this file import each other.
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

/// Everything one hook callback does, whichever transport carried it.
///
/// There are two now — the loopback `POST /agent-hook` a Windows-native agent
/// makes, and the spool file a WSL agent writes — and the three steps below are
/// the whole of what "a hook arrived" means. They live here rather than in the
/// HTTP route because a second copy of them is how the two transports would
/// come to disagree about, say, whether a hook can adopt a session.
///
/// Takes a container rather than a `Ref` for the same reason `reportAgentHook`
/// does: `LauncherControlServer` holds one and has no `Ref` to offer.
///
/// **Never throws.** Adoption and the registry are each wrapped, because
/// neither may be able to fail the callback: over HTTP that would stall the
/// agent that fired it, and over the spool it would stop the drain for every
/// other event in the same tick.
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
  // by hand in one of our own panes. Synchronous and O(1) once a session has
  // been decided about, so a busy agent's stream of hooks costs a set lookup.
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
  // The status pipeline's *primary* input. A hook is authoritative and already
  // in memory, so the registry folds it in here — one map lookup and a
  // precedence — rather than a poll discovering it up to five seconds later.
  try {
    reportAgentHook(
      container,
      agentId: report.agentId,
      sessionId: report.sessionId,
    );
  } on Object catch (error) {
    logger?.warning('Applying a hook report to the registry failed: $error');
  }
  // The durable half, and the only thing in the app that writes an *ending*
  // onto a session row. Almost every callback carries none — see
  // `SessionOutcomeWriter` — so this is a null check on the common path.
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
