import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../core/logging/diagnostics_bootstrap.dart';
import 'package:karmashala_remote/companion.dart';
import '../../features/companion/client/secure_companion_store.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import '../../features/companion/application/companion_providers.dart';
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

  // The companion installed no root handler at all, so its diagnostics went to
  // `debugPrint` — visible only on a cable, in the build that most needs evidence.
  AppLogger.initialize();
  final logger = AppLogger.named('companion.bootstrap');
  logger.info(buildIdentity());
  // Not awaited before the identity line above: a backfill replays that line
  // into the file first, so the log opens by saying which build wrote it.
  await attachDefaultLogFile(Diagnostics.instance);

  // The real protocol client behind the gateway seam. Only this bootstrap wires
  // it, so tests and the desktop build keep the fake and never touch storage.
  final container = ProviderContainer(
    overrides: [
      companionGatewayProvider.overrideWith((ref) {
        // The LAN scout dials the desktop when its beacon is heard, relay otherwise.
        // `onLog` is `info`, not `debug`, or a release build's file stays empty.
        final lanLog = AppLogger.named('companion.lan');
        final gatewayLog = AppLogger.named('companion.gateway');
        final gateway = RemoteCompanionGateway(
          store: SecureCompanionStore(),
          // What this build actually runs on, reported so a push can be routed by it.
          // Nothing spends it yet; a guess would be worse than the honest `unknown`.
          deviceKind: !kIsWeb && (Platform.isAndroid || Platform.isIOS)
              ? CompanionDeviceKind.phone
              : CompanionDeviceKind.desktop,
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
      // Logged rather than swallowed: a phone that silently never notifies looks
      // exactly like a desktop that never raised an attention event.
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
