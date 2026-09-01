/// Finding terminal themes on disk and reading them into a [TerminalPalette].
///
/// The parsers this calls are pure and total; everything fallible here is I/O,
/// and every failure becomes a [ThemeLoadError] carrying a readable reason with
/// no filesystem path in it. Nothing here can throw into the terminal.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/terminal_palette.dart';
import 'ghostty_theme.dart';
import 'warp_theme.dart';

/// Which external terminal a theme file came from.
enum TerminalThemeFormat { ghostty, warp }

/// Bounds on a scan, so a pathological directory tree cannot hang the picker.
const kMaxThemeFiles = 200;
const kMaxThemeDepth = 3;
const kMaxThemeFileBytes = 1024 * 1024;

/// The Warp install channels that keep their themes separately.
const _warpChannels = [
  'Warp',
  'WarpPreview',
  'WarpOss',
  'WarpDev',
  'WarpLocal',
  'WarpIntegration',
];

/// One theme file found on disk.
class DiscoveredTheme {
  const DiscoveredTheme({
    required this.name,
    required this.path,
    required this.format,
  });

  /// The file's base name, without a Warp theme's extension.
  final String name;
  final String path;
  final TerminalThemeFormat format;

  /// What gets persisted in settings: the format plus the path.
  String get id => '${format.name}:$path';

  @override
  bool operator ==(Object other) => other is DiscoveredTheme && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The per-user configuration root, taken from whichever variable the host
/// actually sets.
///
/// `%APPDATA%` is Windows'; `$XDG_CONFIG_HOME` (or `~/.config`) is the POSIX
/// convention Ghostty follows on macOS and Linux. Read off the environment
/// rather than off `Platform` so both conventions stay reachable from a test on
/// either host — and because a Windows session that also sets `HOME` (Git Bash,
/// MSYS) should still be answered with `APPDATA`.
///
/// Reading only `APPDATA` meant every theme directory came back empty off
/// Windows, and the picker reported "none installed" on a machine that had
/// them.
String? _configHome(Map<String, String> environment) {
  final appData = environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) return appData;
  final xdg = environment['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return xdg;
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.join(home, '.config');
}

/// Where Ghostty keeps user themes.
///
/// The reference implementation returns nothing on Windows, which makes a named
/// theme unresolvable there, so this looks beside the config on every host.
List<Directory> ghosttyThemeDirectories({Map<String, String>? environment}) {
  final config = _configHome(environment ?? Platform.environment);
  if (config == null) return const [];
  return [Directory(p.join(config, 'ghostty', 'themes'))];
}

/// Where Warp keeps user themes.
///
/// Windows splits them per install channel under `%APPDATA%`; macOS and Linux
/// use one `~/.warp/themes` for every channel, which is what Warp's own
/// documentation names. Warp's bundled themes live inside its binary rather
/// than on disk, so an empty result genuinely means "none installed" rather
/// than "look harder".
List<Directory> warpThemeDirectories({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final appData = env['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    return [
      for (final channel in _warpChannels)
        Directory(p.join(appData, 'warp', channel, 'data', 'themes')),
    ];
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty) return const [];
  return [Directory(p.join(home, '.warp', 'themes'))];
}

/// Scans [directories] for theme files of [format].
///
/// Ghostty theme files have no extension; Warp's are `.yaml`/`.yml`. Results are
/// sorted and de-duplicated by path so ids are stable between runs. A directory
/// that does not exist, or cannot be read, contributes nothing rather than
/// failing the scan.
List<DiscoveredTheme> discoverTerminalThemes(
  List<Directory> directories, {
  required TerminalThemeFormat format,
  int maxFiles = kMaxThemeFiles,
  int maxDepth = kMaxThemeDepth,
  int maxFileBytes = kMaxThemeFileBytes,
}) {
  final found = <String, DiscoveredTheme>{};

  void scan(Directory dir, int depth) {
    if (depth > maxDepth || found.length >= maxFiles) return;
    final List<FileSystemEntity> entries;
    try {
      if (!dir.existsSync()) return;
      entries = dir.listSync(followLinks: false)
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    } catch (_) {
      return;
    }

    for (final entry in entries) {
      if (found.length >= maxFiles) return;
      if (entry is Directory) {
        scan(entry, depth + 1);
        continue;
      }
      if (entry is! File) continue;

      final name = p.basename(entry.path);
      if (!_looksLikeTheme(name, format)) continue;
      try {
        if (entry.lengthSync() > maxFileBytes) continue;
      } catch (_) {
        continue;
      }

      final key = p.normalize(entry.absolute.path).toLowerCase();
      found.putIfAbsent(
        key,
        () => DiscoveredTheme(
          name: format == TerminalThemeFormat.warp
              ? p.basenameWithoutExtension(entry.path)
              : name,
          path: entry.path,
          format: format,
        ),
      );
    }
  }

  for (final dir in directories) {
    scan(dir, 1);
  }

  return found.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

bool _looksLikeTheme(String name, TerminalThemeFormat format) {
  if (name.startsWith('.')) return false;
  final extension = p.extension(name).toLowerCase();
  return switch (format) {
    TerminalThemeFormat.warp => extension == '.yaml' || extension == '.yml',
    // Ghostty theme files carry no extension, and `config` is the config file
    // rather than a theme.
    TerminalThemeFormat.ghostty =>
      extension.isEmpty && name.toLowerCase() != 'config',
  };
}

/// The outcome of resolving a stored theme id.
sealed class ThemeLoadResult {
  const ThemeLoadResult();
}

class ThemeLoadOk extends ThemeLoadResult {
  const ThemeLoadOk({
    required this.name,
    required this.palette,
    this.notes = const [],
  });

  final String name;
  final TerminalPalette palette;
  final List<String> notes;
}

class ThemeLoadError extends ThemeLoadResult {
  const ThemeLoadError(this.reason);

  /// Readable and path-free, so it is safe to render anywhere.
  final String reason;
}

/// Reads the theme a stored id points at.
///
/// Every failure — a bad id, a deleted file, an unreadable one, a malformed one,
/// one carrying too little colour — comes back as a [ThemeLoadError]. The caller
/// keeps the current theme and shows the reason.
ThemeLoadResult loadTerminalTheme(String id) {
  final separator = id.indexOf(':');
  if (separator <= 0) return const ThemeLoadError('Not a theme reference.');

  final formatName = id.substring(0, separator);
  final path = id.substring(separator + 1);
  if (path.isEmpty) return const ThemeLoadError('Not a theme reference.');

  final format = TerminalThemeFormat.values
      .where((f) => f.name == formatName)
      .firstOrNull;
  if (format == null) return const ThemeLoadError('Unknown theme format.');

  final String content;
  try {
    final file = File(path);
    if (!file.existsSync()) {
      return const ThemeLoadError('The theme file is no longer there.');
    }
    if (file.lengthSync() > kMaxThemeFileBytes) {
      return const ThemeLoadError('The theme file is too large to read.');
    }
    content = file.readAsStringSync();
  } catch (_) {
    return const ThemeLoadError('The theme file could not be read.');
  }

  final name = format == TerminalThemeFormat.warp
      ? p.basenameWithoutExtension(path)
      : p.basename(path);

  switch (format) {
    case TerminalThemeFormat.ghostty:
      final palette = ghosttyPalette(parseGhosttyConfig(content));
      if (!palette.isUsable) {
        return const ThemeLoadError(
          'That file has no usable colours — a theme needs a background, a '
          'foreground and at least one palette colour.',
        );
      }
      return ThemeLoadOk(name: name, palette: palette);
    case TerminalThemeFormat.warp:
      final result = parseWarpTheme(content, fallbackName: name);
      return switch (result) {
        WarpThemeOk(:final name, :final palette, :final notes) => ThemeLoadOk(
          name: name,
          palette: palette,
          notes: notes,
        ),
        WarpThemeError(:final reason) => ThemeLoadError(reason),
      };
  }
}
