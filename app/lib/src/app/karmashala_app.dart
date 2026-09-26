import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/probe/probe_mode.dart';
import '../features/settings/application/settings_controller.dart';
import 'probe_banner.dart';
import '../features/settings/domain/app_theme_mode.dart';
import '../features/ssh/presentation/ssh_prompt_host.dart';
import '../features/terminal/presentation/session_host_banner.dart';
import 'shell/app_shell.dart';
import 'shell/native_menus.dart';
import 'package:karmashala_ui/theme.dart';

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
    final probe = ref.watch(probeModeProvider);
    return MaterialApp(
      title: probe.enabled ? 'Karmashala — PROBE' : 'Karmashala',
      debugShowCheckedModeBanner: false,
      // Above the Navigator, so menus, dialogs and tooltips scale too — not
      // just the routes. The probe banner is outside it so no route covers it.
      builder: (context, child) => ProbeBanner(
        probe: probe,
        child: UiTextScale(scale: uiTextScale, child: child!),
      ),
      theme: AppTheme.light().copyWith(visualDensity: density),
      darkTheme: AppTheme.dark().copyWith(visualDensity: density),
      themeMode: switch (themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      // Inside `home` rather than `builder` because the SSH prompt host needs a
      // Navigator above it to show a host key fingerprint on, and the session
      // host banner one to confirm a restart on. The macOS menu bar is above
      // both, so a strip coming or going never re-creates it: there is one
      // menu bar per app, and a second mounting over the first is an error.
      home: const NativeShellMenus(
        child: SshPromptHost(child: SessionHostBanner(child: AppShell())),
      ),
    );
  }
}
