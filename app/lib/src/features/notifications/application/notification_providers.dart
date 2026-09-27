import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show InboxChanged;
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/persistence.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/probe/probe_mode.dart';
import '../../../core/util/clock_provider.dart';
import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../workspaces/data/workspace_data.dart';
import '../data/desktop_notification_presenter.dart';
import 'attention_presenter.dart';
import 'notification_dispatcher.dart';
import 'session_statuses.dart';

final notificationSettingsRepositoryProvider =
    Provider<NotificationSettingsRepository>((ref) {
      final preferences = ref.watch(appPreferencesProvider);
      return NotificationSettingsRepository(
        read: preferences.read,
        write: preferences.write,
      );
    });

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

/// Sessions waiting on the user now, as the server says (needs approval,
/// failed) — the tray's list.
class SessionAttentionController extends Notifier<List<SessionAttention>> {
  @override
  List<SessionAttention> build() {
    final client = ref.watch(dataClientProvider);
    final changes = client.attentionChanges.listen((change) {
      if (change case InboxChanged(:final snapshot)) set(snapshot.waiting);
    });
    ref.onDispose(changes.cancel);
    return List.unmodifiable(client.attention.waiting);
  }

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

/// Every session's status as the server keeps it — everything that shows or
/// reacts to a status reads this copy. It computes nothing (slice 5c).
final Provider<SessionStatuses> sessionStatusRegistryProvider =
    Provider<SessionStatuses>((ref) {
      final statuses = SessionStatuses(
        ref.watch(dataClientProvider),
        clock: ref.watch(clockProvider),
      );
      ref.onDispose(statuses.dispose);
      return statuses;
    });

/// Turns the server's agent news into toasts, judged against this window's
/// own focus, what it shows and the person's settings. Started by
/// `SystemIntegrationService`, which owns the rest of the desktop
/// integration.
final attentionPresenterProvider = Provider<AttentionPresenter>((ref) {
  final presenter = AttentionPresenter(
    news: ref.watch(dataClientProvider).attentionChanges,
    readSettings: () => ref.read(notificationSettingsControllerProvider),
    isWindowFocused: () => ref.read(windowFocusedProvider),
    visibleSessionIds: () => visibleAgentSessionIds(ref.container),
    onNotify: (event) => ref.read(notificationDispatcherProvider).add(event),
  );
  ref.onDispose(presenter.dispose);
  return presenter;
});

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
