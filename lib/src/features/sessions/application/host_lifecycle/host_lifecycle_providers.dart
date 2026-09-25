import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show LocalHostSessionAccess;
import 'package:karmashala_terminal_runtime/instances.dart'
    show HostTerminalInstance;
import 'package:riverpod/riverpod.dart';

import '../../../agents/application/agent_hook_intake.dart';
import '../../../automations/application/host_automations.dart';
import '../../../agents/application/agent_hook_sweep.dart';
import '../../../../core/database/database_providers.dart';
import '../../../mcp/mcp_tool_dispatcher.dart';
import '../../../remote/application/host_companion_providers.dart';
import '../../../terminal/application/local_host_providers.dart';
import '../../../terminal/application/local_host_startup.dart';
import '../../../terminal/application/terminal_sessions_controller.dart';
import '../session_liveness_reconciler.dart' show panesThatStartedRunning;
import '../session_providers.dart';
import '../session_signals.dart';
import 'host_lifecycle_source.dart';
import 'host_lifecycle_subscriber.dart';
import 'local_host_lifecycle_source.dart';

/// This machine's host feed, or null when local panes are not host-backed or
/// no host may be reached — never under `flutter test`, which a test overrides.
final hostLifecycleSourceProvider = Provider<HostLifecycleSource?>((ref) {
  if (!ref.watch(hostBackedLocalPanesProvider)) return null;
  final access = ref.watch(localHostSessionAccessProvider);
  return access == null ? null : LocalHostLifecycleSource(access.socketPath);
});

/// Whether a row runs on this machine, under this machine's host.
final sessionRunsOnThisMachineProvider = Provider<bool Function(Session)>((
  ref,
) {
  final database = ref.watch(databaseProvider);
  return (session) => sessionRunsOnThisMachine(database, session);
});

/// The subscriber to this machine's host, or null without a source. **Watched
/// at startup**, beside the liveness reconciler: unwatched, it never dials.
final hostLifecycleSubscriberProvider = Provider<HostLifecycleSubscriber?>((
  ref,
) {
  final source = ref.watch(hostLifecycleSourceProvider);
  if (source == null) return null;
  final hookLog = AppLogger.named('agent-hooks');
  final subscriber = HostLifecycleSubscriber(
    source: source,
    sessionDao: ref.watch(sessionDaoProvider),
    // The host wrote the row; this only says to read it again.
    onStatusChanged: (sessionId) => ref.publishSessionChange(
      sessionId == null
          ? const SessionChange(kinds: {SessionChangeKind.status})
          : SessionChange.statusChanged(sessionId),
    ),
    hasLivePane: (paneId) =>
        ref.exists(terminalSessionsControllerProvider) &&
        (ref
                .read(terminalSessionsControllerProvider.notifier)
                .instanceFor(paneId)
                ?.liveness
                .value
                .isLive ??
            false),
    onHook: (hook) => applyHostRelayedAgentHook(
      ref.container,
      agentId: hook.agentId,
      event: hook.event,
      body: hook.body,
      receivedAt: hook.receivedAt,
      held: hook.holdId != null,
      paneSessionId: hook.paneSessionId,
      logger: hookLog,
    ),
    onAttached: () => unawaited(sweepHostHooks(ref.container, logger: hookLog)),
    // The host serves agents' MCP; this app runs the tools it forwards.
    mcpTools: ref.read(mcpToolDispatcherProvider),
    // The host serves the phone companion; this app answers what only it can.
    companion: ref.read(hostCompanionLinkProvider),
    // The host runs automations; this app answers what only it can.
    automations: ref.read(hostAutomationsLinkProvider),
  );
  // A pane starting on the host may have just started the host itself: the
  // launch's start failed, or the host went away since.
  ref.listen(terminalSessionsControllerProvider, (previous, next) {
    if (subscriber.isWatching) return;
    final started = panesThatStartedRunning(previous?.liveness, next.liveness);
    if (started.any((paneId) => _isLocalHostPane(ref, paneId))) {
      subscriber.nudge();
    }
  });
  ref.onDispose(() => unawaited(subscriber.dispose()));
  // The first dial waits for the launch's start of this machine's host (and the
  // hook sweep after it) rather than racing it. It never fails.
  final starting = ref.watch(localHostStartupProvider);
  if (starting == null) {
    subscriber.start();
  } else {
    unawaited(starting.then((_) => subscriber.start()));
  }
  return subscriber;
});

/// Whether a row's lifecycle status comes from this machine's host rather than
/// being inferred from panes and hooks: the host holds it, or its pane is one
/// of the host's. False whenever there is no feed to follow.
final sessionFollowsHostFactsProvider = Provider<bool Function(Session)>(
  (ref) => (session) {
    final subscriber = ref.read(hostLifecycleSubscriberProvider);
    if (subscriber == null) return false;
    if (subscriber.knows(session.id)) return true;
    final paneId = session.paneId;
    return paneId != null && _isLocalHostPane(ref, paneId);
  },
);

/// Whether this machine's host says it is running [String] session now.
final sessionRunningOnHostProvider = Provider<bool Function(String)>(
  (ref) =>
      (sessionId) =>
          ref.read(hostLifecycleSubscriberProvider)?.isRunning(sessionId) ??
          false,
);

/// Ends the session this machine's host runs for a row, when no pane of ours
/// holds it; null where local panes are not host-backed or no host may be
/// reached. The host records the ending; nothing here writes the row.
final hostedSessionEnderProvider =
    Provider<Future<void> Function(String sessionId)?>((ref) {
      if (!ref.watch(hostBackedLocalPanesProvider)) return null;
      final access = ref.watch(localHostSessionAccessProvider);
      if (access == null) return null;
      return (sessionId) => access.endSession(hostSessionIdOf(sessionId));
    });

bool _isLocalHostPane(Ref ref, String paneId) {
  if (!ref.exists(terminalSessionsControllerProvider)) return false;
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  return instance is HostTerminalInstance &&
      instance.access is LocalHostSessionAccess;
}
