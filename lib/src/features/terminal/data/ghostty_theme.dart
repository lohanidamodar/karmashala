/// Ghostty config/theme files: `key = value` lines. Both parsers here are pure
/// functions over a string that never throw — a malformed file yields fewer
/// keys, so a broken theme can never reach the terminal as a crash.
library;

import '../domain/terminal_palette.dart';

/// Parses a Ghostty config or theme file. Every key maps to a *list*, because
/// `palette` is spelled as a repeated key; scalars take the last entry.
Map<String, List<String>> parseGhosttyConfig(String content) {
  final result = <String, List<String>>{};
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final equals = line.indexOf('=');
    if (equals < 0) continue;

    final key = line.substring(0, equals).trim();
    if (key.isEmpty) continue;

    // Trim *before* looking for an inline comment: the leading space in
    // `background = #000000` would otherwise make the colour itself look like
    // one, because an inline comment is a `#` preceded by whitespace.
    var value = _stripInlineComment(line.substring(equals + 1).trim()).trim();
    if (value.length >= 2) {
      final first = value[0];
      if ((first == '"' || first == "'") && value.endsWith(first)) {
        value = value.substring(1, value.length - 1);
      }
    }
    result.putIfAbsent(key, () => <String>[]).add(value);
  }
  return result;
}

/// Drops an inline `# comment`, which only counts when preceded by whitespace
/// and outside quotes — a `#` at the start of a value is a colour.
String _stripInlineComment(String value) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (char == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (char == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (char == '#' && !inSingle && !inDouble && i > 0) {
      final previous = value[i - 1];
      if (previous == ' ' || previous == '\t') return value.substring(0, i);
    }
  }
  return value;
}

/// Maps parsed Ghostty keys onto a [TerminalPalette]. Anything unusable — an
/// unknown key, a colour we cannot read, a palette index outside 0–15 — is
/// dropped silently: a theme is allowed to be partial.
TerminalPalette ghosttyPalette(Map<String, List<String>> config) {
  String? colorOf(String key) {
    final values = config[key];
    if (values == null || values.isEmpty) return null;
    return normalizeHexColor(values.last);
  }

  final ansi = <int, String>{};
  for (final entry in config['palette'] ?? const <String>[]) {
    final equals = entry.indexOf('=');
    if (equals < 0) continue;
    final index = int.tryParse(entry.substring(0, equals).trim());
    if (index == null || index < 0 || index >= kAnsiPaletteSize) continue;
    final color = normalizeHexColor(entry.substring(equals + 1));
    if (color != null) ansi[index] = color;
  }

  return TerminalPalette(
    background: colorOf('background'),
    foreground: colorOf('foreground'),
    cursor: colorOf('cursor-color'),
    selectionBackground: colorOf('selection-background'),
    selectionForeground: colorOf('selection-foreground'),
    ansi: ansi,
  );
}
