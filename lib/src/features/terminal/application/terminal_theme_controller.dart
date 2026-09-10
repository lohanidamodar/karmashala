import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../data/theme_discovery.dart';

/// Themes found on this machine, Ghostty first then Warp. Scanning is
/// synchronous file I/O, so only Settings ever reads this.
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

/// The imported theme, resolved from the stored id, or null on the built-in
/// one. Nothing throws — a [ThemeLoadError] leaves the terminal's colours alone
/// and Settings shows the reason.
final importedTerminalThemeProvider = Provider<ThemeLoadResult?>((ref) {
  final id = ref.watch(settingsControllerProvider).terminalThemeSource;
  if (id == null || id.isEmpty) return null;
  return loadTerminalTheme(id);
});
