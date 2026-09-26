import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/probe/probe_mode.dart';
import '../../editor/application/editor_hook_checks.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_outcome_writer.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_hook_spool_drainer.dart';
import 'agent_status_providers.dart';
import 'hook_payload_field.dart';
import 'agent_providers.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/where_you_are.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_rebind_providers.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import '../../sessions/application/host_lifecycle/relayed_agent_hook.dart';

/// Drains the spool directories a file-reporting agent writes into, applying
/// each payload exactly as the HTTP route does. An empty list starts no timer.
final agentHookSpoolDrainerProvider = Provider<AgentHookSpoolDrainer>((ref) {
  final logger = AppLogger.named('agent-hooks');
  final drainer = AgentHookSpoolDrainer(
    enabled: !ref.read(probeModeProvider).enabled,
    onEvent: (event) {
      applyAgentHookCallback(
        ref.container,
        agentId: event.agentId,
        event: event.event,
        body: event.body,
        observedAt: event.firedAt,
        paneSessionId: event.paneSessionId,
        logger: logger,
      );
      // The server's checkpoint recorder never sees a spooled hook: a spool
      // write has no reply to hold, so its tool has already run.
      forwardAgentHookToServer(
        ref.container,
        agentId: event.agentId,
        event: event.event,
        body: event.body,
        receivedAt: event.firedAt,
        paneSessionId: event.paneSessionId,
        logger: logger,
      );
    },
  );
  ref.onDispose(drainer.dispose);
  return drainer;
});

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

/// Hands a hook this app took itself — on its own `/agent-hook` route or from
/// a spool — to the server, whose checkpoint recorder reads the turns of every
/// pane on this machine. Unheld by construction: the agent was answered first.
/// Nothing when no server link is open. **Never throws.**
void forwardAgentHookToServer(
  ProviderContainer container, {
  required String? agentId,
  required String? event,
  required String body,
  DateTime? receivedAt,
  String? paneSessionId,
  AppLogger? logger,
}) {
  if (agentId == null || agentId.isEmpty || event == null || event.isEmpty) {
    return;
  }
  try {
    container
        .read(hostLifecycleSubscriberProvider)
        ?.forwardHook(
          RelayedAgentHook(
            agentId: agentId,
            event: event,
            body: body,
            receivedAt: (receivedAt ?? DateTime.now()).toUtc(),
            paneSessionId: paneSessionId,
          ),
        );
  } on Object catch (error) {
    logger?.warning('Forwarding a hook to the server failed: $error');
  }
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
  // server's to adopt: it receives every hook, and this app reports its panes
  // (`PaneFactsReporter`).
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
  // A tool that wrote a file open in the editor: check it now, not at the
  // next poll. Only stats; the buffer decides what a change means.
  try {
    checkEditorFilesFromHook(
      container,
      agentId: report.agentId,
      event: event,
      body: body,
      agentSessionId: report.sessionId,
    );
  } on Object catch (error) {
    logger?.warning('Re-checking editor files from a hook failed: $error');
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
