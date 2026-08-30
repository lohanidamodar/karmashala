import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_status_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../data/notification_presenter.dart';
import '../data/notification_settings_repository.dart';
import '../data/desktop_notification_presenter.dart';
import '../domain/notification_settings.dart';
import '../domain/session_attention.dart';
import 'agent_status_watcher.dart';
import 'notification_dispatcher.dart';
import 'watched_session_loader.dart';

final notificationSettingsRepositoryProvider =
    Provider<NotificationSettingsRepository>(
      (ref) => NotificationSettingsRepository(ref.watch(databaseProvider)),
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

/// Whether the app window currently has OS focus.
///
/// Written by `SystemIntegrationService`, which is the one object already
/// listening to window events. Defaults to focused: the app shows its window on
/// launch, and assuming focus is the quiet answer.
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

/// Bumped when something outside the window asks for it to be brought forward —
/// a clicked toast. `SystemIntegrationService` listens and raises the window;
/// this feature has no business calling `window_manager` itself.
class WindowRaiseRequestController extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final windowRaiseRequestProvider =
    NotifierProvider<WindowRaiseRequestController, int>(
      WindowRaiseRequestController.new,
    );

/// Where a notification is actually delivered.
///
/// Windows is the platform this was verified on; macOS and Linux go down the
/// same code path but were not exercised (see `docs/loop-reports/loop-42.md`).
/// Anywhere else falls back to silence. Constructing the presenter is cheap and
/// safe: it does not touch the platform channel until the first
/// [NotificationPresenter.show].
final notificationPresenterProvider = Provider<NotificationPresenter>((ref) {
  if (!DesktopNotificationPresenter.isSupportedHere) {
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

final watchedSessionLoaderProvider = Provider<WatchedSessionLoader>(
  (ref) => WatchedSessionLoader(
    sessionDao: ref.watch(sessionDaoProvider),
    importedSessionDao: ref.watch(importedSessionDaoProvider),
    installationDao: ref.watch(agentInstallationDaoProvider),
    hookReports: ref.watch(agentHookReportsProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// The always-on watcher. Started by `SystemIntegrationService`, which owns the
/// rest of the desktop integration.
final agentStatusWatcherProvider = Provider<AgentStatusWatcher>((ref) {
  final watcher = AgentStatusWatcher(
    statusService: ref.watch(agentStatusServiceProvider),
    loadSessions: () => ref.read(watchedSessionLoaderProvider).load(),
    readSettings: () => ref.read(notificationSettingsControllerProvider),
    isWindowFocused: () => ref.read(windowFocusedProvider),
    visibleSessionIds: () => visibleAgentSessionIds(ref.container),
    onAttention: (attention) =>
        ref.read(sessionAttentionProvider.notifier).set(attention),
    onNotify: (event) => ref.read(notificationDispatcherProvider).add(event),
  );
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// The CLI session ids currently rendered in the app.
///
/// The selection providers hold workspace row ids; the status pipeline is keyed
/// by the CLI's own session id, so each selection is resolved through its DAO.
/// Takes a container rather than a `Ref` so `SystemIntegrationService`, which
/// only holds one, can call it too.
Set<String> visibleAgentSessionIds(ProviderContainer container) {
  final read = container.read;
  final ids = <String>{};
  final nativeId = read(selectedSessionIdProvider);
  if (nativeId != null) {
    final native = read(sessionDaoProvider).getById(nativeId);
    final externalId = native?.externalSessionId;
    if (externalId != null) ids.add(externalId);
  }
  final importedId = read(selectedImportedSessionIdProvider);
  if (importedId != null) {
    final imported = read(importedSessionDaoProvider).getById(importedId);
    if (imported != null) ids.add(imported.externalId);
  }
  return ids;
}

/// Selects a session so the app shows it, walking up to its repository and
/// project the way the command palette does — selecting a session alone leaves
/// the explorer pointing somewhere else.
void focusWatchedSession(
  ProviderContainer container, {
  required String openId,
  required bool imported,
}) {
  final read = container.read;
  final repositoryId = imported
      ? read(importedSessionDaoProvider).getById(openId)?.repositoryId
      : read(sessionDaoProvider).getById(openId)?.repositoryId;
  if (repositoryId == null) return;
  final repository = read(repositoryDaoProvider).getById(repositoryId);
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
