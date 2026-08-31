import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import 'companion_shell.dart';

/// Root widget of the companion build. The desktop's theme, the phone's
/// shell, and none of the desktop's providers — no database, no settings
/// store, no window chrome.
///
/// The one thing it *does* change about the theme is density, and it does so
/// by measuring its own width rather than by knowing it is a phone
/// (CLAUDE.md §6): [UiDensity.wrap] installs the scope that the shared
/// Explorer cards read, so the same widgets draw for a thumb here and for a
/// mouse on the desktop.
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
      builder: (context, child) => UiDensity.wrap(context, child!),
      home: const CompanionShell(),
    );
  }
}
