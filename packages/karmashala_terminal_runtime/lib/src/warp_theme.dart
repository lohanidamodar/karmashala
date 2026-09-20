/// Warp theme files: YAML. Pure, and failure is a value — a corrupt file in a
/// scanned directory can only ever be skipped.
library;

import 'package:yaml/yaml.dart';

import 'package:karmashala_terminal_core/grid.dart';

/// The eight colour names Warp uses under both `normal` and `bright`.
const _warpColorNames = [
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
];

/// The outcome of reading one Warp theme file.
sealed class WarpThemeResult {
  const WarpThemeResult();
}

class WarpThemeOk extends WarpThemeResult {
  const WarpThemeOk({
    required this.name,
    required this.palette,
    this.notes = const [],
  });

  final String name;
  final TerminalPalette palette;

  /// Things the file asked for that a terminal cell cannot express — a gradient
  /// background, for instance. The theme still imports; these are shown so the
  /// result is not silently different from what the user saw in Warp.
  final List<String> notes;
}

class WarpThemeError extends WarpThemeResult {
  const WarpThemeError(this.reason);

  /// Readable, and free of filesystem paths so it is safe to show anywhere.
  final String reason;
}

/// Parses one Warp theme. [fallbackName] is used when the file carries no
/// `name`; callers pass the file name without its extension.
WarpThemeResult parseWarpTheme(String yamlText, {String? fallbackName}) {
  final Object? document;
  try {
    document = loadYaml(yamlText);
  } on YamlException catch (e) {
    return WarpThemeError(e.message);
  } catch (_) {
    return const WarpThemeError('Invalid YAML.');
  }

  if (document is! Map) {
    return const WarpThemeError('Theme file must contain a YAML object.');
  }

  final notes = <String>[];
  if (document['background'] is Map) {
    notes.add('Background gradient not supported.');
  }
  if (document['accent'] is Map) notes.add('Accent gradient not supported.');
  if (document.containsKey('background_image')) {
    notes.add('Background image not supported.');
  }

  final colors = document['terminal_colors'];
  final ansi = <int, String>{};
  if (colors is Map) {
    _readGroup(colors['normal'], 0, ansi);
    _readGroup(colors['bright'], 8, ansi);
  }

  final palette = TerminalPalette(
    background: _readColor(document['background']),
    foreground: _readColor(document['foreground']),
    // Warp's cursor is optional and falls back to the accent colour.
    cursor: _readColor(document['cursor']) ?? _readColor(document['accent']),
    ansi: ansi,
  );

  if (!palette.isUsable) {
    return const WarpThemeError(
      'Theme must include a background, a foreground and at least one '
      'terminal colour.',
    );
  }

  final name = document['name'];
  return WarpThemeOk(
    name: name is String && name.trim().isNotEmpty
        ? _cleanName(name)
        : (fallbackName ?? 'Warp theme'),
    palette: palette,
    notes: notes,
  );
}

void _readGroup(Object? group, int offset, Map<int, String> into) {
  if (group is! Map) return;
  for (var i = 0; i < _warpColorNames.length; i++) {
    final color = _readColor(group[_warpColorNames[i]]);
    if (color != null) into[offset + i] = color;
  }
}

/// Reads a colour that may be a scalar or a gradient map, taking the first
/// usable endpoint of a gradient.
String? _readColor(Object? value) {
  if (value is String) return normalizeHexColor(value);
  if (value is! Map) return null;
  for (final key in ['top', 'bottom', 'left', 'right']) {
    final endpoint = value[key];
    if (endpoint is String) {
      final color = normalizeHexColor(endpoint);
      if (color != null) return color;
    }
  }
  return null;
}

String _cleanName(String raw) => raw
    .replaceAll(RegExp(r'[\x00-\x1f]'), '')
    .replaceAll(RegExp(r'[\\/]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
