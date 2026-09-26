import '../../workspaces/data/workspace_data.dart';
import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/probe/probe_mode.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_status_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/host_lifecycle/host_agent_statuses.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_notifications/persistence.dart';
import '../data/desktop_notification_presenter.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/attention.dart';
import 'agent_status_watcher.dart';
import 'attention_inbox.dart';
import 'notification_dispatcher.dart';
import 'session_status_registry.dart';
import 'watched_session_loader.dart';

final notificationSettingsRepositoryProvider =
    Provider<NotificationSettingsRepository>(
      (ref) =>
          NotificationSettingsRepository(ref.watch(appPreferencesProvider)),
    );

/// Holds [NotificationSettings], persisting every change.
class NotificationSettingsController extends Notifier<NotificationSettings> {
  @override
  NotificationSettings build() =>
      ref.watch(notificationSettingsRepositoryProvider).load();

  void setEnabled(bool value) => _update(state.copyWith(enabled: value));

  void setOnlyWhenUnfocused(bool value) =>
      _update(state.copyWith(onlyWhenUnfocused: value));

  void setNotifyWhenFinished(bool value) =>
      _update(state.copyWith(notifyWhenFinished: value));

  void setNotifyWhenAttentionNeeded(bool value) =>
      _update(state.copyWith(notifyWhenAttentionNeeded: value));

  void _update(NotificationSettings next) {
    state = next;
    ref.read(notificationSettingsRepositoryProvider).save(next);
  }
}

final notificationSettingsControllerProvider =
    NotifierProvider<NotificationSettingsController, NotificationSettings>(
      NotificationSettingsController.new,
    );

/// Whether the app window currently has OS focus. Defaults to focused: the app
/// shows its window on launch, and assuming focus is the quiet answer.
class WindowFocusController extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool focused) {
    if (state != focused) state = focused;
  }
}

final windowFocusedProvider = NotifierProvider<WindowFocusController, bool>(
  WindowFocusController.new,
);

/// Sessions currently waiting on the user. Ambient state, refreshed every poll.
class SessionAttentionController extends Notifier<List<SessionAttention>> {
  @override
  List<SessionAttention> build() => const [];

  void set(List<SessionAttention> next) {
    if (!_same(state, next)) state = List.unmodifiable(next);
  }

  static bool _same(List<SessionAttention> a, List<SessionAttention> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final sessionAttentionProvider =
    NotifierProvider<SessionAttentionController, List<SessionAttention>>(
      SessionAttentionController.new,
    );

/// Bumped when something outside the window asks for it to be brought forward.
/// `SystemIntegrationService` listens; this feature never calls `window_manager`.
class WindowRaiseRequestController extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final windowRaiseRequestProvider =
    NotifierProvider<WindowRaiseRequestController, int>(
      WindowRaiseRequestController.new,
    );

/// Where a notification is actually delivered. Verified on Windows only; macOS
/// and Linux share the path untested, and anywhere else falls back to silence.
final notificationPresenterProvider = Provider<NotificationPresenter>((ref) {
  // A probe shows no toasts: on Windows the first one rewrites the Start Menu
  // shortcut the real app's toasts are delivered through.
  if (!DesktopNotificationPresenter.isSupportedHere ||
      ref.read(probeModeProvider).enabled) {
    return const NoopNotificationPresenter();
  }
  final presenter = DesktopNotificationPresenter(
    onActivated: (payload) {
      focusWatchedSession(
        ref.container,
        openId: payload.openId,
        imported: payload.imported,
      );
      ref.read(windowRaiseRequestProvider.notifier).bump();
    },
  );
  ref.onDispose(presenter.dispose);
  return presenter;
});

final notificationDispatcherProvider = Provider<NotificationDispatcher>((ref) {
  final dispatcher = NotificationDispatcher(
    presenter: ref.watch(notificationPresenterProvider),
  );
  ref.onDispose(dispatcher.dispose);
  return dispatcher;
});

final Provider<WatchedSessionLoader>
watchedSessionLoaderProvider = Provider<WatchedSessionLoader>(
  (ref) => WatchedSessionLoader(
    sessionDao: ref.watch(sessionsDataProvider),
    importedSessionDao: ref.watch(importedSessionsProvider),
    installationDao: ref.watch(agentInstallationsDataProvider),
    hookReports: ref.watch(agentHookReportsProvider),
    clock: ref.watch(clockProvider),
    // Asked through `exists`, never built: building the controller starts the
    // scrollback autosave timer. No controller means no pane of ours is live.
    isPaneLive: (paneId) =>
        ref.exists(terminalSessionsControllerProvider) &&
        (ref
                .read(terminalSessionsControllerProvider.notifier)
                .instanceFor(paneId)
                ?.liveness
                .value
                .isLive ??
            false),
    isRunningOnHost: ref.watch(sessionRunningOnHostProvider),
    transcriptPathFor: (sessionId) => ref.exists(sessionStatusRegistryProvider)
        ? ref
              .read(sessionStatusRegistryProvider)
              .transcriptPathForOpenId(sessionId)
        : null,
  ),
);

/// The one status registry — everything that shows or reacts to a status reads
/// it. Cycled only by `AgentStatusWatcher.start()`; reading starts nothing.
///
/// A session this machine's host holds is rendered from the host's own status
/// ([hostAgentStatusesProvider]); only panes no host holds — the in-app PTY
/// path, imported sessions — are computed here.
final Provider<SessionStatusRegistry>
sessionStatusRegistryProvider = Provider<SessionStatusRegistry>((ref) {
  final hostStatuses = ref.watch(hostAgentStatusesProvider);
  final registry = SessionStatusRegistry(
    statusService: ref.watch(agentStatusServiceProvider),
    agents: ref.watch(agentRegistryProvider),
    loadSessions: () => ref.read(watchedSessionLoaderProvider).load(),
    clock: ref.watch(clockProvider),
    // The pane's own screen, for the sessions that have one.
    readTail: (session) {
      if (session.imported) return const [];
      return sessionTerminalTailForPane(
        ref,
        session.paneId,
        agentId: session.key.agentId,
      );
    },
    // One store scan for every session still missing a transcript path, on the
    // registry's own slow interval — not one per badge per tick.
    resolveTranscripts: () =>
        ref.read(sessionTranscriptLocatorProvider).index(),
    visibleSessionIds: () => visibleAgentSessionIds(ref.container),
    heldByHost: (session) =>
        ref.read(hostLifecycleSubscriberProvider)?.knows(session.openId) ??
        false,
    hostStatusFor: (session) => hostStatuses.of(session.openId),
    // The panes ride this cycle rather than a ticker of their own: the server
    // adopts what a person starts by hand in one, and keeps titles and
    // conversation ids itself (slice 2b). Sent only when a pane changed.
    onCycle: (_) async => ref.read(paneFactsReporterProvider).report(),
  );
  final moves = hostStatuses.changes.listen(registry.hostStatusMoved);
  ref.onDispose(() {
    unawaited(moves.cancel());
    registry.dispose();
  });
  return registry;
});

/// The always-on watcher. Started by `SystemIntegrationService`, which owns the
/// rest of the desktop integration.
final agentStatusWatcherProvider = Provider<AgentStatusWatcher>((ref) {
  final watcher = AgentStatusWatcher(
    registry: ref.watch(sessionStatusRegistryProvider),
    readSettings: () => ref.read(notificationSettingsControllerProvider),
    isWindowFocused: () => ref.read(windowFocusedProvider),
    visibleSessionIds: () => visibleAgentSessionIds(ref.container),
    onAttention: (attention) =>
        ref.read(sessionAttentionProvider.notifier).set(attention),
    onInbox: (update) =>
        ref.read(attentionInboxProvider.notifier).apply(update),
    onNotify: (event) => ref.read(notificationDispatcherProvider).add(event),
  );
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// Hands one hook callback to the status registry — the primary status path.
/// Reading the registry starts nothing, so this cannot block the calling agent.
void reportAgentHook(
  ProviderContainer container, {
  required String agentId,
  required String sessionId,
}) {
  if (sessionId.isEmpty) return;
  container
      .read(sessionStatusRegistryProvider)
      .hookReported(AgentSessionKey(agentId, sessionId));
}

/// The session ids currently rendered, under every key the status pipeline
/// might hold them: the workspace row id and the CLI's own session id.
Set<String> visibleAgentSessionIds(ProviderContainer container) {
  final read = container.read;
  final ids = <String>{};
  final nativeId = read(selectedSessionIdProvider);
  if (nativeId != null) {
    ids.add(nativeId);
    final native = read(sessionsDataProvider).getById(nativeId);
    final externalId = native?.externalSessionId;
    if (externalId != null) ids.add(externalId);
  }
  final importedId = read(selectedImportedSessionIdProvider);
  if (importedId != null) {
    ids.add(importedId);
    final imported = read(importedSessionsProvider).getById(importedId);
    if (imported != null) ids.add(imported.externalId);
  }
  return ids;
}

/// Selects a session so the app shows it, walking up to its repository and
/// project — selecting a session alone leaves the explorer pointing elsewhere.
void focusWatchedSession(
  ProviderContainer container, {
  required String openId,
  required bool imported,
}) {
  final read = container.read;
  final repositoryId = imported
      ? read(importedSessionsProvider).getById(openId)?.repositoryId
      : read(sessionsDataProvider).getById(openId)?.repositoryId;
  if (repositoryId == null) return;
  final repository = read(workspaceDataProvider).repository(repositoryId);
  if (repository == null) return;

  read(selectedProjectIdProvider.notifier).select(repository.projectId);
  read(selectedRepositoryIdProvider.notifier).select(repository.id);
  if (imported) {
    read(selectedSessionIdProvider.notifier).select(null);
    read(selectedImportedSessionIdProvider.notifier).select(openId);
  } else {
    read(selectedImportedSessionIdProvider.notifier).select(null);
    read(selectedSessionIdProvider.notifier).select(openId);
  }
}
