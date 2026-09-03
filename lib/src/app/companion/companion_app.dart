import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import 'companion_shell.dart';

/// Root widget of the companion build. The desktop's theme, the phone's
/// shell, and none of the desktop's providers — no database, no settings
/// store, no window chrome.
///
/// The one thing it *does* change about the theme is density: [UiDensity.wrap]
/// installs the scope that the shared Explorer cards read, so the same widgets
/// draw for a thumb here and for a mouse on the desktop.
///
/// It asks the platform, not its own width. This build runs on a 350px folded
/// phone and on a 1280px tablet and both of them are held in a hand — a width
/// rule drew the tablet for a mouse it does not have. Layout below here still
/// branches on width, and still should (CLAUDE.md §6); what a finger needs from
/// a target does not shrink because the screen grew.
class CompanionApp extends StatelessWidget {
  const CompanionApp({this.navigatorKey, super.key});

  /// Lets a tapped notification navigate without a context.
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Karmashala',
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
