/// Finding terminal themes on disk and reading them into a [TerminalPalette].
/// Every failure is a [ThemeLoadError]; nothing here can throw into a terminal.
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

/// The per-user configuration root, from whichever variable the host sets, not
/// from `Platform` — a Windows session may also set `HOME` (Git Bash, MSYS).
String? _configHome(Map<String, String> environment) {
  final appData = environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) return appData;
  final xdg = environment['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return xdg;
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.posix.join(home, '.config');
}

/// The separator style a discovered root belongs to: these paths often describe
/// another platform's disk, so the branch that found the root says which.
p.Context _contextFor(Map<String, String> environment) {
  final appData = environment['APPDATA'];
  return appData != null && appData.isNotEmpty ? p.windows : p.posix;
}

/// Where Ghostty keeps user themes. The reference implementation returns
/// nothing on Windows, which makes a named theme unresolvable there, so this
/// looks beside the config on every host.
List<Directory> ghosttyThemeDirectories({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final config = _configHome(env);
  if (config == null) return const [];
  return [Directory(_contextFor(env).join(config, 'ghostty', 'themes'))];
}

/// Where Warp keeps user themes. Its bundled ones live inside the binary, so an
/// empty result means "none installed" rather than "look harder".
List<Directory> warpThemeDirectories({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final appData = env['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    return [
      for (final channel in _warpChannels)
        Directory(p.windows.join(appData, 'warp', channel, 'data', 'themes')),
    ];
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty) return const [];
  return [Directory(p.posix.join(home, '.warp', 'themes'))];
}

/// Scans [directories] for theme files of [format], sorted and de-duplicated by
/// path so ids are stable. An unreadable directory contributes nothing.
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

/// Reads the theme a stored id points at. Every failure — a bad id, a deleted,
/// unreadable or malformed file, one carrying too little colour — comes back as
/// a [ThemeLoadError], and the caller keeps the current theme.
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
