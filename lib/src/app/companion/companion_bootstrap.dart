import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../core/logging/build_identity.dart';
import '../../core/logging/diagnostics.dart';
import '../../core/logging/diagnostics_bootstrap.dart';
import '../../features/companion/client/companion_gateway.dart';
import '../../features/companion/client/remote_companion_gateway.dart';
import '../../features/companion/client/secure_companion_store.dart';
import '../../features/remote/client/lan_path.dart';
import '../../features/companion/notifications/attention_notification.dart';
import '../../features/companion/notifications/companion_notifier.dart';
import '../../features/companion/presentation/session_view_screen.dart';
import 'companion_app.dart';
import 'companion_lifecycle.dart';
import 'multicast_lock_channel.dart';

/// Boots the companion build. Deliberately none of the desktop bootstrap: no
/// database, no PTYs, no environment discovery, no control server, no tray,
/// no window manager — a client, and only a client.
Future<void> runCompanionApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The companion had no logging at all: it never installed the root handler,
  // so nothing reached the ring buffer or the file, and its own diagnostics
  // went to `debugPrint` — visible under `flutter run`, and in a release APK
  // only to whoever has the phone on a cable running `adb logcat`. That is
  // exactly the build whose failures need evidence, and "it just sits on
  // connecting" was the whole of more than one bug report as a result.
  AppLogger.initialize();
  final logger = AppLogger.named('companion.bootstrap');
  logger.info(buildIdentity());
  // Not awaited before the identity line above: that line is what a backfill
  // replays into the file first, so the log opens by saying which build wrote
  // it even though the file itself arrives later.
  await attachDefaultLogFile(Diagnostics.instance);

  // The real protocol client behind the gateway seam, its pairing record in
  // the platform keystore. Only this bootstrap wires it, so tests — and the
  // desktop build, which never runs this file — keep the fake and never
  // touch secure storage.
  final container = ProviderContainer(
    overrides: [
      companionGatewayProvider.overrideWith((ref) {
        // The LAN scout dials the desktop directly when its beacon is heard,
        // relay otherwise. Android drops multicast without a real
        // WifiManager.MulticastLock, held via the runner's own channel; on
        // networks that still drop it the scout stays inert and the relay
        // carries everything — best effort by design.
        //
        // `onLog` is wired here and nowhere else. Every diagnostic line the
        // gateway, the protocol client and the transports already write went
        // nowhere in a release build, so a phone that would not connect
        // offered no evidence at all — which is how "it just says connecting"
        // became the whole of a bug report. Lifecycle only: none of these
        // calls is ever handed a payload, a key or a rendezvous.
        //
        // `info`, not `debug`: `AppLogger.debug` is `Level.FINE`, below the
        // default root level, so these would be filtered out before any sink
        // saw them and the file would be empty in the one build that has no
        // other way to be inspected. They are low-frequency lifecycle lines.
        final lanLog = AppLogger.named('companion.lan');
        final gatewayLog = AppLogger.named('companion.gateway');
        final gateway = RemoteCompanionGateway(
          store: SecureCompanionStore(),
          lan: LanPathScout(
            lock: !kIsWeb && Platform.isAndroid
                ? ChannelMulticastLock()
                : const NoopMulticastLock(),
            onLog: lanLog.info,
          ),
          onLog: gatewayLog.info,
        );
        ref.onDispose(() => unawaited(gateway.close()));
        return gateway;
      }),
    ],
  );
  final navigatorKey = GlobalKey<NavigatorState>();

  // Attention events → local notifications; tapping one opens the session.
  // Mobile platforms only, and best-effort: a phone that refuses the
  // permission still gets the full app.
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    final notifier = CompanionNotifier();
    try {
      await notifier.initialize(
        onOpenSession: (sessionId) {
          navigatorKey.currentState?.push(
            MaterialPageRoute<void>(
              builder: (_) => SessionViewScreen(sessionId: sessionId),
            ),
          );
        },
      );
      container
          .read(companionGatewayProvider)
          .attentionEvents
          .listen((event) => notifier.show(notificationFor(event)));
    } catch (error, stackTrace) {
      // Notifications are a convenience; the app must still run without them.
      // Logged rather than swallowed: a phone that silently never notifies is
      // indistinguishable from a desktop that never raised an attention event,
      // and the two have entirely different fixes.
      logger.warning('Local notifications unavailable.', error, stackTrace);
    }
  }

  // On resume with the link down, re-dial immediately; in the background the
  // link simply rests — an FCM wake is the design's background answer.
  CompanionLifecycleReconnector(
    container.read(companionGatewayProvider),
    onLog: AppLogger.named('companion.lifecycle').info,
  ).attach();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: CompanionApp(navigatorKey: navigatorKey),
    ),
  );
}
