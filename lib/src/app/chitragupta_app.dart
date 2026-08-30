import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/application/settings_controller.dart';
import '../features/settings/domain/app_theme_mode.dart';
import '../features/ssh/presentation/ssh_prompt_host.dart';
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
    final themeMode = ref.watch(
      settingsControllerProvider.select((s) => s.themeMode),
    );
    final compact = ref.watch(
      settingsControllerProvider.select((s) => s.compactDensity),
    );
    final density = compact ? VisualDensity.compact : VisualDensity.standard;
    return MaterialApp(
      title: 'Chitragupta',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light().copyWith(visualDensity: density),
      darkTheme: AppTheme.dark().copyWith(visualDensity: density),
      themeMode: switch (themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      // Wrapped in the SSH prompt host so a connection begun anywhere in the
      // app can put a host key fingerprint in front of the user. It sits inside
      // `home` rather than `builder` because it needs a Navigator above it to
      // show a dialog on.
      home: const SshPromptHost(child: AppShell()),
    );
  }
}
