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
import '../../../agents/application/agent_hook_sweep.dart';
import '../../../environments/application/environment_providers.dart';
import '../../../repositories/application/repository_providers.dart';
import '../../../terminal/application/local_host_providers.dart';
import '../../../terminal/application/terminal_sessions_controller.dart';
import '../session_liveness_reconciler.dart' show panesThatStartedRunning;
import '../session_providers.dart';
import '../session_signals.dart';
import 'host_lifecycle_source.dart';
import 'host_lifecycle_subscriber.dart';
import 'local_host_lifecycle_source.dart';
import 'session_on_this_machine.dart';

/// This machine's host feed, or null when local panes are not host-backed or
/// no host may be reached — never under `flutter test`, which a test overrides.
final hostLifecycleSourceProvider = Provider<HostLifecycleSource?>((ref) {
  if (!ref.watch(hostBackedLocalPanesProvider)) return null;
  final access = ref.watch(localHostSessionAccessProvider);
  return access == null ? null : LocalHostLifecycleSource(access.socketPath);
});

/// The one writer of a hosted row's lifecycle status; each write is published.
final sessionLifecycleRecorderProvider = Provider<SessionLifecycleRecorder>((
  ref,
) {
  final recorder = SessionLifecycleRecorder(ref.watch(sessionDaoProvider));
  final changes = recorder.changes.listen(
    (change) =>
        ref.publishSessionChange(SessionChange.statusChanged(change.sessionId)),
  );
  ref.onDispose(() {
    unawaited(changes.cancel());
    unawaited(recorder.dispose());
  });
  return recorder;
});

final sessionRunsOnThisMachineProvider = Provider<bool Function(Session)>((
  ref,
) {
  final repositories = ref.watch(repositoryDaoProvider);
  final environments = ref.watch(executionEnvironmentDaoProvider);
  return (session) => sessionRunsOnThisMachine(
    session,
    repositories: repositories,
    environments: environments,
  );
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
    recorder: ref.watch(sessionLifecycleRecorderProvider),
    sessionDao: ref.watch(sessionDaoProvider),
    runsOnThisMachine: ref.watch(sessionRunsOnThisMachineProvider),
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
      paneSessionId: hook.paneSessionId,
      logger: hookLog,
    ),
    onAttached: () => unawaited(sweepHostHooks(ref.container, logger: hookLog)),
  );
  // A pane starting on the host may have just started the host itself.
  ref.listen(terminalSessionsControllerProvider, (previous, next) {
    if (subscriber.isWatching) return;
    final started = panesThatStartedRunning(previous?.liveness, next.liveness);
    if (started.any((paneId) => _isLocalHostPane(ref, paneId))) {
      subscriber.nudge();
    }
  });
  ref.onDispose(() => unawaited(subscriber.dispose()));
  subscriber.start();
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

bool _isLocalHostPane(Ref ref, String paneId) {
  if (!ref.exists(terminalSessionsControllerProvider)) return false;
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  return instance is HostTerminalInstance &&
      instance.access is LocalHostSessionAccess;
}
