import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import 'companion_shell.dart';

/// Root widget of the companion build: the desktop's theme, the phone's shell,
/// and none of the desktop's providers. Density comes from the platform.
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
