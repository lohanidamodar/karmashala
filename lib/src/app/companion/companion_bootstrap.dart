import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/companion/client/companion_gateway.dart';
import '../../features/companion/notifications/attention_notification.dart';
import '../../features/companion/notifications/companion_notifier.dart';
import '../../features/companion/presentation/session_view_screen.dart';
import 'companion_app.dart';

/// Boots the companion build. Deliberately none of the desktop bootstrap: no
/// database, no PTYs, no environment discovery, no control server, no tray,
/// no window manager — a client, and only a client.
Future<void> runCompanionApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
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
    } catch (_) {
      // Notifications are a convenience; the app must still run without them.
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: CompanionApp(navigatorKey: navigatorKey),
    ),
  );
}
