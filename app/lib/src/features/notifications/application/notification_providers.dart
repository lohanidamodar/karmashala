import 'dart:async';

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show ApprovalAnswerRequest, PromptAsk, SessionPromptRefusal;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show InboxChanged;
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/persistence.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:riverpod/riverpod.dart';

import '../../../app/shell/phone_routes.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/probe/probe_mode.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_list_snapshot.dart'
    show sessionsPrimedProvider;
import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/session_prompt_answers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../workspaces/data/workspace_data.dart';
import '../data/desktop_notification_presenter.dart';
import '../data/device_notification_store.dart';
import '../data/phone_notification_presenter.dart';
import 'attention_presenter.dart';
import 'notification_dispatcher.dart';
import 'session_statuses.dart';

final _log = AppLogger.named('notifications');

final notificationSettingsRepositoryProvider =
    Provider<NotificationSettingsRepository>((ref) {
      final preferences = ref.watch(appPreferencesProvider);
      return NotificationSettingsRepository(
        read: preferences.read,
        write: preferences.write,
      );
    });

/// Holds [NotificationSettings], persisting every change: at the server for a
/// desktop, and on the device for a phone ([DeviceNotificationStore]), so a
/// phone's switches never change the desktop's toasts.
class NotificationSettingsController extends Notifier<NotificationSettings> {
  bool _onDevice = false;
  bool _changed = false;

  @override
  NotificationSettings build() {
    _changed = false;
    _onDevice = ref.watch(clientCapabilitiesProvider).localNotifications;
    if (_onDevice) {
      unawaited(_loadFromDevice(ref.watch(deviceNotificationStoreProvider)));
      return DeviceNotificationStore.phoneDefaults;
    }
    return ref.watch(notificationSettingsRepositoryProvider).load();
  }

  Future<void> _loadFromDevice(DeviceNotificationStore store) async {
    final kept = await store.loadSettings();
    // A switch flipped before the file was read wins over it.
    if (ref.mounted && !_changed) state = kept;
  }

  void setLevel(NotifyLevel level) => _update(state.copyWith(level: level));

  void setOnlyWhenUnfocused(bool value) =>
      _update(state.copyWith(onlyWhenUnfocused: value));

  /// Focus's half here: Only when I'm needed, remembering [before].
  void startFocus(FocusMemory before) =>
      _update(state.copyWith(level: NotifyLevel.whenNeeded, focus: before));

  /// Ends Focus, putting back the level it replaced.
  void endFocus() {
    final before = state.focus;
    if (before == null) return;
    _update(state.copyWith(level: before.level, endFocus: true));
  }

  void _update(NotificationSettings next) {
    state = next;
    _changed = true;
    if (_onDevice) {
      unawaited(ref.read(deviceNotificationStoreProvider).saveSettings(next));
      return;
    }
    ref.read(notificationSettingsRepositoryProvider).save(next);
  }
}

final notificationSettingsControllerProvider =
    NotifierProvider<NotificationSettingsController, NotificationSettings>(
      NotificationSettingsController.new,
    );

/// Whether the app is in front: the window's OS focus on a desktop, the app's
/// lifecycle on a phone (`ServerSession.appBackgrounded`). Defaults to
/// focused: the app shows its window on launch, and that is the quiet answer.
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
/// and Linux share the path untested, a phone has its own presenter
/// ([PhoneNotificationPresenter]), and anywhere else falls back to silence.
final notificationPresenterProvider = Provider<NotificationPresenter>((ref) {
  final capabilities = ref.read(capabilitiesProvider);
  if (capabilities.localNotifications && !ref.read(probeModeProvider).enabled) {
    final presenter = PhoneNotificationPresenter(
      onActivated: (payload) => openNotifiedSession(ref.container, payload),
    );
    ref.onDispose(presenter.dispose);
    return presenter;
  }
  // A probe shows no toasts: on Windows the first one rewrites the Start Menu
  // shortcut the real app's toasts are delivered through.
  if (!capabilities.osToasts || ref.read(probeModeProvider).enabled) {
    return const NoopNotificationPresenter();
  }
  // The prompt each toast's Allow once / Deny was raised for, as the status
  // stood when it was shown: a click that lands later answers only that one.
  final raisedFor = <String, PromptAsk>{};
  final presenter = DesktopNotificationPresenter(
    onActivated: (payload) {
      focusWatchedSession(
        ref.container,
        openId: payload.openId,
        imported: payload.imported,
      );
      ref.read(windowRaiseRequestProvider.notifier).bump();
    },
    // The toast's Allow once / Deny ([kApprovalNotificationActions]), answered
    // as the dock answers: the guarded path refuses once the prompt is gone,
    // so a toast clicked late types nothing. With the app in the background
    // there is nobody to tell about a refusal; the toast just goes.
    onAction: (payload, action) async {
      if (payload.imported || action > 1) return;
      try {
        await ref
            .read(sessionPromptAnswersProvider)
            .answer(
              ApprovalAnswerRequest(
                sessionId: payload.openId,
                approve: action == 0,
                ask: raisedFor[payload.openId],
              ),
            );
      } on SessionPromptRefusal catch (refusal) {
        _log.info(
          'A notification answer for ${payload.openId} was not sent: '
          '${refusal.message}',
        );
      }
    },
  );
  ref.onDispose(presenter.dispose);
  return _PromptRecordingPresenter(presenter, (request) {
    if (request.actions.isEmpty) return;
    final payload = NotificationPayload.decode(request.payload);
    if (payload == null) return;
    final report = ref
        .read(sessionStatusRegistryProvider)
        .reportForOpenId(payload.openId);
    if (report == null) {
      raisedFor.remove(payload.openId);
    } else {
      raisedFor[payload.openId] = PromptAsk.drawnFrom(report);
    }
  });
});

/// [inner], telling [shown] of each toast before it goes up.
class _PromptRecordingPresenter implements NotificationPresenter {
  _PromptRecordingPresenter(this._inner, this._shown);

  final NotificationPresenter _inner;
  final void Function(NotificationRequest request) _shown;

  @override
  bool get isSupported => _inner.isSupported;

  @override
  Future<void> show(NotificationRequest request) {
    _shown(request);
    return _inner.show(request);
  }

  @override
  void dispose() => _inner.dispose();
}

final notificationDispatcherProvider = Provider<NotificationDispatcher>((ref) {
  final dispatcher = NotificationDispatcher(
    presenter: ref.watch(notificationPresenterProvider),
    perSession: ref.read(capabilitiesProvider).localNotifications,
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
/// own focus, what it shows and the person's settings. Started by one owner
/// per client: `SystemIntegrationService` on a desktop, which owns the rest of
/// the desktop integration, and `startPhoneNotifications` on a phone.
final attentionPresenterProvider = Provider<AttentionPresenter>((ref) {
  final presenter = AttentionPresenter(
    news: ref.watch(dataClientProvider).attentionChanges,
    readSettings: () => ref.read(notificationSettingsControllerProvider),
    isWindowFocused: () => ref.read(windowFocusedProvider),
    visibleSessionIds: () => visibleAgentSessionIds(ref.container),
    onNotify: (event) => ref.read(notificationDispatcherProvider).add(event),
    onQuiet: ref.read(capabilitiesProvider).localNotifications
        ? (event) => ref.read(notificationDispatcherProvider).add(event)
        : null,
  );
  ref.onDispose(presenter.dispose);
  return presenter;
});

/// The session ids currently rendered, under every key the status pipeline
/// might hold them: the workspace row id and the CLI's own session id. On a
/// phone's shell, only while the session's page is up: under the tabs the
/// selection stays, but nothing of it is on screen.
Set<String> visibleAgentSessionIds(ProviderContainer container) {
  final read = container.read;
  if (phoneSessionPageDown(container)) return const {};
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

/// Whether this is a phone's shell with its session page down: the selection
/// stays under the tabs, but no session is on screen. Always false on a
/// desktop. What a notification is held for and what the Inbox marks seen
/// both ask this, so "on screen" and "seen" agree.
bool phoneSessionPageDown(ProviderContainer container) {
  final read = container.read;
  return !read(clientCapabilitiesProvider).systemIntegration &&
      read(phoneShellRouterProvider).current != null &&
      !read(phoneWorkbenchProvider);
}

/// Selects a session so the app shows it, walking up to its repository and
/// project — selecting a session alone leaves the explorer pointing elsewhere.
/// False, selecting nothing, when the session or its repository is gone.
bool focusWatchedSession(
  ProviderContainer container, {
  required String openId,
  required bool imported,
}) {
  final read = container.read;
  final repositoryId = imported
      ? read(importedSessionsProvider).getById(openId)?.repositoryId
      : read(sessionsDataProvider).getById(openId)?.repositoryId;
  if (repositoryId == null) return false;
  final repository = read(workspaceDataProvider).repository(repositoryId);
  if (repository == null) return false;

  read(selectedProjectIdProvider.notifier).select(repository.projectId);
  read(selectedRepositoryIdProvider.notifier).select(repository.id);
  if (imported) {
    read(selectedSessionIdProvider.notifier).select(null);
    read(selectedImportedSessionIdProvider.notifier).select(openId);
  } else {
    read(selectedImportedSessionIdProvider.notifier).select(null);
    read(selectedSessionIdProvider.notifier).select(openId);
  }
  return true;
}

/// Opens the session a tapped phone notification names, once the server has
/// said what the sessions are: a stale list must not act (decision 9). Its
/// page comes up; a session that is gone opens the Inbox instead.
void openNotifiedSession(
  ProviderContainer container,
  NotificationPayload payload,
) {
  void open() {
    final found = focusWatchedSession(
      container,
      openId: payload.openId,
      imported: payload.imported,
    );
    if (found) {
      // Opened here, not left to the shell's selection listener: re-selecting
      // the session already selected moves nothing, and a shell not built yet
      // hears nothing.
      container.read(phoneWorkbenchProvider.notifier).open();
      return;
    }
    _log.info('A notified session (${payload.openId}) is gone; the Inbox.');
    _showInbox(container);
  }

  if (container.read(sessionsPrimedProvider)) return open();
  late final ProviderSubscription<bool> waiting;
  waiting = container.listen<bool>(sessionsPrimedProvider, (_, primed) {
    if (!primed) return;
    waiting.close();
    open();
  });
}

/// The Inbox tab, once the phone's shell is up: a cold start may be answered
/// before its first frame.
void _showInbox(ProviderContainer container, {int framesLeft = 30}) {
  final PhoneShellRoutes? routes;
  try {
    routes = container.read(phoneShellRouterProvider).current;
  } on Object {
    return; // The session closed first: a switch of server.
  }
  if (routes != null) return routes.showInbox();
  if (framesLeft == 0) return;
  SchedulerBinding.instance.addPostFrameCallback((_) {
    _showInbox(container, framesLeft: framesLeft - 1);
  });
  SchedulerBinding.instance.ensureVisualUpdate();
}

/// Takes down [openId]'s notification, where this client keeps one per
/// session (a phone); nothing elsewhere. For an ask answered elsewhere.
Future<void> withdrawSessionNotification(
  ProviderContainer container,
  String openId,
) async {
  final presenter = container.read(notificationPresenterProvider);
  if (presenter is PhoneNotificationPresenter) {
    await presenter.withdraw(openId);
  }
}
