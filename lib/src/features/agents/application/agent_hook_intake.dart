import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../checkpoints/application/checkpoint_turn_hints.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_outcome_writer.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_hook_spool_drainer.dart';
import 'agent_status_providers.dart';
import 'hook_payload_field.dart';
import 'agent_providers.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/where_you_are.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_rebind_providers.dart';

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
  // A launched pane whose CLI has moved to a conversation we never named — a
  // `/clear`, a fork, a resume that minted a fresh id. Left alone, the row goes
  // on reading a transcript that stopped and the session looks finished.
  try {
    final rebound = rebindSessionFromHook(
      container,
      agentId: report.agentId,
      conversationId: report.sessionId,
      body: body,
    );
    if (rebound != null) {
      logger?.info(
        'Session $rebound is on conversation ${report.sessionId} now; its '
        'pane is live and the one it named had gone quiet.',
      );
    }
  } on Object catch (error) {
    logger?.warning('Re-pointing a session from a hook failed: $error');
  }
  // Where the agent is working *now*. An agent pane paints a TUI and emits no
  // OSC 7, so its hook is the only live reading of this.
  try {
    recordAgentDirectoryFromHook(
      container,
      agentId: report.agentId,
      agentSessionId: report.sessionId,
      body: body,
    );
  } on Object catch (error) {
    logger?.warning('Recording an agent working directory failed: $error');
  }
  // Before the status moves: a turn's checkpoint is labelled with its prompt.
  try {
    recordCheckpointHints(
      container,
      agentId: report.agentId,
      agentSessionId: report.sessionId,
      event: event,
      body: body,
    );
  } on Object catch (error) {
    logger?.warning('Recording checkpoint hints from a hook failed: $error');
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
        .record(agentSessionId: report.sessionId, ending: report.ending);
  } on Object catch (error) {
    logger?.warning('Recording a session ending from a hook failed: $error');
  }
  return report;
}

/// Files the `cwd` a hook carried under **our** session id.
///
/// The field is declared per agent on [AgentHookSpec.cwdPath], so nothing here
/// parses a shape. The environment comes from the session's own checkout: a
/// path an agent reports is spelled for the machine it runs on, and reading it
/// as this one would move the tree to another machine's folder.
void recordAgentDirectoryFromHook(
  ProviderContainer container, {
  required String agentId,
  required String agentSessionId,
  required String body,
}) {
  if (agentId.isEmpty || agentSessionId.isEmpty) return;
  final path =
      container.read(agentRegistryProvider).byId(agentId)?.hooks?.cwdPath ??
      const <String>[];
  if (path.isEmpty) return;
  final cwd = hookStringAt(path, body);
  if (cwd.isEmpty) return;
  final session = container
      .read(sessionDaoProvider)
      .getByExternalSessionId(agentSessionId);
  if (session == null) return;
  final environmentId = container
      .read(repositoryDaoProvider)
      .getById(session.repositoryId)
      ?.path
      .environmentId;
  if (environmentId == null) return;
  container
      .read(agentWorkingDirectoriesProvider.notifier)
      .record(
        session.id,
        EnvironmentPath(environmentId: environmentId, path: cwd),
      );
}
