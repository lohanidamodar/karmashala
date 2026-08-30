import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'companion_shell.dart';

/// Root widget of the companion build. The desktop's theme, the phone's
/// shell, and none of the desktop's providers — no database, no settings
/// store, no window chrome.
class CompanionApp extends StatelessWidget {
  const CompanionApp({this.navigatorKey, super.key});

  /// Lets a tapped notification navigate without a context.
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chitragupta',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const CompanionShell(),
    );
  }
}
