import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/application/settings_controller.dart';
import '../features/settings/domain/app_theme_mode.dart';
import '../features/ssh/presentation/ssh_prompt_host.dart';
import 'shell/app_shell.dart';
import 'theme/app_theme.dart';
import 'theme/ui_text_scale.dart';

/// Root application widget: theming and the desktop shell. The `ProviderScope`
/// is installed in `main.dart`, with the database override.
class KarmashalaApp extends ConsumerWidget {
  const KarmashalaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      settingsControllerProvider.select((s) => s.themeMode),
    );
    final compact = ref.watch(
      settingsControllerProvider.select((s) => s.compactDensity),
    );
    final density = compact ? VisualDensity.compact : VisualDensity.standard;
    final uiTextScale = ref.watch(
      settingsControllerProvider.select((s) => s.uiTextScale),
    );
    return MaterialApp(
      title: 'Karmashala',
      debugShowCheckedModeBanner: false,
      // Above the Navigator, so menus, dialogs and tooltips scale too — not
      // just the routes.
      builder: (context, child) =>
          UiTextScale(scale: uiTextScale, child: child!),
      theme: AppTheme.light().copyWith(visualDensity: density),
      darkTheme: AppTheme.dark().copyWith(visualDensity: density),
      themeMode: switch (themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      // Inside `home` rather than `builder` because the SSH prompt host needs a
      // Navigator above it to show a host key fingerprint on.
      home: const SshPromptHost(child: AppShell()),
    );
  }
}
