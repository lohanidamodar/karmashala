/// The seam an FCM message handler calls once `firebase_messaging` exists.
///
/// This loop deliberately ships no Firebase dependency — without a real
/// Firebase project config the google-services Gradle plugin breaks the
/// Android build. What remains to finish push on a device:
///
/// 1. Create a Firebase project, add this Android app id, and put its
///    `google-services.json` under `android/app/`.
/// 2. Add `firebase_core` + `firebase_messaging` to `pubspec.yaml` and the
///    `com.google.gms.google-services` plugin to the Gradle files —
///    companion builds only.
/// 3. In the companion bootstrap: initialise Firebase, request permission,
///    and pass a real `pushTokenSource` (FCM's `getToken()`) to
///    `RemoteCompanionGateway` — the `notifications.register` round-trip is
///    already wired behind it.
/// 4. Wire `FirebaseMessaging.onMessage` and `onBackgroundMessage` to call
///    [handleCompanionPushMessage] with `message.data`.
/// 5. Run the relay with `RELAY_FCM_SERVICE_ACCOUNT` pointing at the same
///    project's service-account JSON (see `packages/relay/README.md`).
library;

import '../../features/companion/client/secure_companion_store.dart';
import '../../features/companion/notifications/companion_notifier.dart';
import '../../features/companion/push/companion_push_receiver.dart';

/// Handles one push message's `data` map: unseal the opaque payload with the
/// stored device key, render the local notification. Safe to call from a
/// background isolate — it builds everything it needs.
Future<void> handleCompanionPushMessage(
  Map<Object?, Object?> data, {
  CompanionPushReceiver? receiver,
}) async {
  await (receiver ?? _defaultReceiver()).handleData(data);
}

CompanionPushReceiver _defaultReceiver() {
  final notifier = CompanionNotifier();
  var ready = false;
  return CompanionPushReceiver(
    store: SecureCompanionStore(),
    show: (notification) async {
      if (!ready) {
        ready = true;
        // No navigator in a background isolate; a tap opens the app, and the
        // foreground listener owns navigation from there.
        await notifier.initialize(onOpenSession: (_) {});
      }
      await notifier.show(notification);
    },
  );
}
