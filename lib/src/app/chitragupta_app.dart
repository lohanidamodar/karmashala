import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shell/app_shell.dart';
import 'theme/app_theme.dart';

/// Root application widget.
///
/// Provides theming and renders the desktop shell. The `ProviderScope` is
/// installed in `main.dart` (with the database override) so that bootstrap can
/// supply already-initialised dependencies.
class ChitraguptaApp extends ConsumerWidget {
  const ChitraguptaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Chitragupta',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}
