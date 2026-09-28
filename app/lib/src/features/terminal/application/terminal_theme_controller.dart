import 'package:karmashala_terminal_core/grid.dart';
import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';
import 'package:karmashala_terminal_runtime/themes.dart';

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

/// The stored scheme reference (`terminalThemeSource`), selected on its own so
/// an unrelated settings change neither re-reads a theme file nor repaints
/// every pane.
final terminalThemeSourceProvider = Provider<String?>((ref) {
  final source = ref.watch(
    settingsControllerProvider.select((s) => s.terminalThemeSource),
  );
  return source == null || source.isEmpty ? null : source;
});

/// The built-in scheme in force; Match app when the stored value is none, an
/// imported file, or a scheme this build does not ship.
final terminalSchemeProvider = Provider<TerminalScheme>((ref) {
  return TerminalSchemes.fromSource(ref.watch(terminalThemeSourceProvider));
});

/// The imported theme, resolved from the stored id, or null when none is
/// chosen (Match app or a built-in scheme). Nothing throws — a
/// [ThemeLoadError] leaves the terminal on Match app and Settings shows the
/// reason.
final importedTerminalThemeProvider = Provider<ThemeLoadResult?>((ref) {
  final id = ref.watch(terminalThemeSourceProvider);
  if (id == null || TerminalSchemes.isSchemeSource(id)) return null;
  return loadTerminalTheme(id);
});

/// The palette every terminal pane paints with over the Match-app base: the
/// chosen built-in scheme's, an imported file's, or null for Match app. Local
/// and host-owned panes read the same value, so a change reaches all of them.
final terminalPaletteProvider = Provider<TerminalPalette?>((ref) {
  final source = ref.watch(terminalThemeSourceProvider);
  if (source == null) return null;
  if (TerminalSchemes.isSchemeSource(source)) {
    return TerminalSchemes.fromSource(source).palette;
  }
  final loaded = ref.watch(importedTerminalThemeProvider);
  return loaded is ThemeLoadOk ? loaded.palette : null;
});

/// What the terminal is drawn in, in words: the scheme's name, or an imported
/// theme's; Match app when a stored theme file no longer resolves.
final terminalSchemeLabelProvider = Provider<String>((ref) {
  final source = ref.watch(terminalThemeSourceProvider);
  if (source == null || TerminalSchemes.isSchemeSource(source)) {
    return ref.watch(terminalSchemeProvider).name;
  }
  final loaded = ref.watch(importedTerminalThemeProvider);
  return loaded is ThemeLoadOk ? loaded.name : TerminalSchemes.matchApp.name;
});
