import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../data/theme_discovery.dart';

/// Themes found on this machine, Ghostty first then Warp.
///
/// Scanning is synchronous file I/O, so this is only ever read by the Settings
/// screen — never by the terminal itself.
final discoveredTerminalThemesProvider = Provider<List<DiscoveredTheme>>((ref) {
  return [
    ...discoverTerminalThemes(
      ghosttyThemeDirectories(),
      format: TerminalThemeFormat.ghostty,
    ),
    ...discoverTerminalThemes(
      warpThemeDirectories(),
      format: TerminalThemeFormat.warp,
    ),
  ];
});

/// The imported theme, resolved from the stored id — or `null` when the user is
/// on the built-in theme.
///
/// A [ThemeLoadError] here is the whole point of the design: the terminal keeps
/// its current colours and Settings shows the reason. Nothing throws.
final importedTerminalThemeProvider = Provider<ThemeLoadResult?>((ref) {
  final id = ref.watch(settingsControllerProvider).terminalThemeSource;
  if (id == null || id.isEmpty) return null;
  return loadTerminalTheme(id);
});
