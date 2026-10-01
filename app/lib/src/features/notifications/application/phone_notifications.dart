import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show InboxChanged;
import 'package:karmashala_notifications/attention.dart';

import '../../../core/data/data_providers.dart';
import '../../explorer/application/session_list_snapshot.dart'
    show sessionsPrimedProvider;
import '../data/device_notification_store.dart';
import '../data/phone_notification_presenter.dart';
import 'notification_providers.dart';

/// Starts a phone's notifications for the session [container] is (Stage 3
/// step 2): the server's agent news judged by the desktop's policy, the
/// plugin's tap, the tap that started the app, and, once, the permission.
/// The desktop's owner is `SystemIntegrationService`; a client has one.
void startPhoneNotifications(
  ProviderContainer container, {
  required AppLogger logger,
}) {
  final presenter = container.read(notificationPresenterProvider);
  if (presenter is! PhoneNotificationPresenter) {
    logger.info('Notifications: none on this phone (a probe).');
    return;
  }
  // The phone's own settings, read from its file now rather than on the
  // first piece of news, which would be judged against the defaults.
  container.read(notificationSettingsControllerProvider);
  container.read(attentionPresenterProvider).start();
  container.read(answeredAskWithdrawalProvider);
  logger.info('Notifications: started by the phone session, one per session.');
  unawaited(_afterStart(container, presenter, logger));
}

/// Takes down a session's ask notification once the server's inbox no longer
/// holds its needs-you item: answered here, on the desktop, or anywhere else
/// (Stage 3 step 4). Heard only while the link is up, as the asks are.
///
/// An ask still in the dispatcher's window is dropped with it, so it never
/// goes up answered. The first inbox this session hears also withdraws the
/// asks a previous server session showed that it does not hold: after a
/// switch of server nothing else would.
final answeredAskWithdrawalProvider = Provider<void>((ref) {
  final presenter = ref.watch(notificationPresenterProvider);
  if (presenter is! PhoneNotificationPresenter) return;
  final client = ref.watch(dataClientProvider);
  final dispatcher = ref.watch(notificationDispatcherProvider);
  Set<String> asking(AttentionInbox inbox) => {
    for (final item in inbox.items)
      if (item.kind == InboxItemKind.needsApproval) item.session.openId,
  };
  var before = asking(client.attention.inbox);
  var first = true;
  final changes = client.attentionChanges.listen((change) {
    if (change is! InboxChanged) return;
    final now = asking(change.snapshot.inbox);
    final gone = before.difference(now);
    if (first) gone.addAll(presenter.shownAsks.difference(now));
    first = false;
    for (final openId in gone) {
      dispatcher.dropAsk(openId);
      unawaited(presenter.withdraw(openId));
    }
    before = now;
  });
  ref.onDispose(changes.cancel);
});

Future<void> _afterStart(
  ProviderContainer container,
  PhoneNotificationPresenter presenter,
  AppLogger logger,
) async {
  if (!await presenter.initialize()) {
    logger.warning('Notifications: the plugin did not start on this phone.');
    return;
  }
  final launched = await presenter.takeLaunchPayload();
  if (launched != null) {
    logger.info('Started by the notification for ${launched.openId}.');
    try {
      openNotifiedSession(container, launched);
    } on Object catch (error) {
      logger.warning('Opening the notified session failed: $error');
    }
  }
  await _askPermissionOnce(container, presenter, logger);
}

/// After the first pairing, not at the first launch: once the server has
/// answered, with the app in front to show the prompt. Asked once per
/// install; refused, the settings page says so and links to the system's.
Future<void> _askPermissionOnce(
  ProviderContainer container,
  PhoneNotificationPresenter presenter,
  AppLogger logger,
) async {
  try {
    final store = container.read(deviceNotificationStoreProvider);
    if (await store.permissionAsked()) return;
    await _until(
      container,
      () =>
          container.read(sessionsPrimedProvider) &&
          container.read(windowFocusedProvider),
      listening: [sessionsPrimedProvider, windowFocusedProvider],
    );
    if (await store.permissionAsked()) return;
    await store.markPermissionAsked();
    final allowed = await presenter.requestPermission();
    logger.info('Notifications: the permission was asked; allowed=$allowed.');
    container.invalidate(phoneNotificationPermissionProvider);
  } on Object catch (error) {
    // The session closed while waiting: the next one asks.
    logger.info('Notifications: the permission was not asked: $error');
  }
}

/// Completes once [ready] holds, re-checked whenever one of [listening]
/// changes; never, if the container goes first.
Future<void> _until(
  ProviderContainer container,
  bool Function() ready, {
  required List<ProviderListenable<bool>> listening,
}) {
  if (ready()) return Future.value();
  final done = Completer<void>();
  final subscriptions = <ProviderSubscription<bool>>[];
  void check() {
    if (done.isCompleted || !ready()) return;
    for (final subscription in subscriptions) {
      subscription.close();
    }
    done.complete();
  }

  for (final provider in listening) {
    subscriptions.add(container.listen<bool>(provider, (_, _) => check()));
  }
  check();
  return done.future;
}

/// Whether the OS lets this phone notify; null where it cannot be read or the
/// client is not a phone. Read again when the app comes back to the front, as
/// it does from the system settings.
final phoneNotificationPermissionProvider = FutureProvider.autoDispose<bool?>((
  ref,
) async {
  ref.watch(windowFocusedProvider);
  final presenter = ref.watch(notificationPresenterProvider);
  if (presenter is! PhoneNotificationPresenter) return null;
  return presenter.permissionGranted();
});

/// Opens the phone's own notification settings for this app, where a blocked
/// permission is given back. Nothing off a phone.
void openPhoneNotificationSettings(WidgetRef ref) {
  final presenter = ref.read(notificationPresenterProvider);
  if (presenter is PhoneNotificationPresenter) {
    unawaited(presenter.openSystemSettings());
  }
}
