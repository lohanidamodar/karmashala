import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../sessions/application/session_outcome_writer.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_status_providers.dart';
import 'hook_payload_field.dart';
import 'agent_providers.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/where_you_are.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_rebind_providers.dart';

/// A hook the session host took and relayed, applied as the HTTP route applied
/// one — at the time the host received it. Nothing waits on it: the server
/// held a `PreToolUse` for its own checkpoint before relaying it. **Never
/// throws.**
void applyHostRelayedAgentHook(
  ProviderContainer container, {
  required String agentId,
  required String event,
  required String body,
  required DateTime receivedAt,
  String? paneSessionId,
  AppLogger? logger,
}) {
  applyAgentHookCallback(
    container,
    agentId: agentId,
    event: event,
    body: body,
    observedAt: receivedAt,
    paneSessionId: paneSessionId,
    logger: logger,
  );
}

/// Everything one hook callback does, whichever transport carried it — a second
/// copy of these steps is how the two would come to disagree. **Never throws.**
///
/// [paneSessionId] is the `KARMASHALA_SESSION_ID` the hook's pane carries, or
/// null from a hook installed before it was forwarded.
AgentStatusReport applyAgentHookCallback(
  ProviderContainer container, {
  required String? agentId,
  required String? event,
  required String body,
  DateTime? observedAt,
  String? paneSessionId,
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
  // A session the user started by hand in one of our own panes is the
  // server's to adopt: it receives every hook and reads its own terminals'
  // screens (slice 5c). The session's status is the server's too.
  // A launched pane whose CLI has moved to a conversation we never named — a
  // `/clear`, a fork, a resume that minted a fresh id. Left alone, the row goes
  // on reading a transcript that stopped and the session looks finished.
  try {
    final rebound = rebindSessionFromHook(
      container,
      agentId: report.agentId,
      conversationId: report.sessionId,
      event: event,
      body: body,
      paneSessionId: paneSessionId,
      observedAt: report.observedAt,
    );
    if (rebound != null) {
      logger?.info(
        'Session $rebound is on conversation ${report.sessionId} now; '
        '${paneSessionId == null ? 'inferred: its pane is live and the one it '
                  'named had ended or gone quiet' : 'its own pane said so'}.',
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
      .read(sessionsDataProvider)
      .getByExternalSessionId(agentSessionId);
  if (session == null) return;
  final environmentId = container
      .read(workspaceDataProvider)
      .repository(session.repositoryId)
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
