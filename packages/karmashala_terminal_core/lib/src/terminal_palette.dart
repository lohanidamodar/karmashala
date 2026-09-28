import 'package:flutter/painting.dart';
import 'package:xterm2/xterm.dart';

/// The 16 ANSI slots, in the order every terminal theme format numbers them.
const kAnsiPaletteSize = 16;

final _hexColor = RegExp(r'^#?(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$');

/// Normalises a theme colour to `#rrggbb`, or `null`. 8-digit hex is rejected:
/// a cell has no alpha, and dropping it silently would render a theme wrong.
String? normalizeHexColor(String? value) {
  if (value == null) return null;
  var text = value.trim();
  if (text.length >= 2) {
    final first = text[0];
    if ((first == '"' || first == "'") && text.endsWith(first)) {
      text = text.substring(1, text.length - 1).trim();
    }
  }
  if (!_hexColor.hasMatch(text)) return null;
  final digits = text.startsWith('#') ? text.substring(1) : text;
  final expanded = digits.length == 3
      ? digits.split('').map((c) => '$c$c').join()
      : digits;
  return '#${expanded.toLowerCase()}';
}

/// A colour theme — one read from an external terminal, or a built-in scheme
/// (`TerminalSchemes`) — as a **sparse** set of overrides, which is what makes
/// [applyTo] safe on a half-read file.
class TerminalPalette {
  const TerminalPalette({
    this.background,
    this.foreground,
    this.cursor,
    this.selectionBackground,
    this.selectionForeground,
    this.ansi = const {},
  });

  final String? background;
  final String? foreground;
  final String? cursor;
  final String? selectionBackground;
  final String? selectionForeground;

  /// ANSI colours by index: 0–7 normal, 8–15 bright.
  final Map<int, String> ansi;

  /// Whether this is enough of a theme to be worth applying: a background, a
  /// foreground and at least one ANSI colour. Below that the result is the
  /// current theme with a colour or two disturbed, which looks like a bug.
  bool get isUsable =>
      background != null && foreground != null && ansi.isNotEmpty;

  /// Whether this palette draws on a light ground, or null when it carries no
  /// background of its own.
  bool? get isLight {
    final ground = _toColor(background);
    return ground == null ? null : ground.computeLuminance() > 0.5;
  }

  bool get isEmpty =>
      background == null &&
      foreground == null &&
      cursor == null &&
      selectionBackground == null &&
      selectionForeground == null &&
      ansi.isEmpty;

  /// Layers this palette over [base], keeping every colour it does not carry.
  TerminalTheme applyTo(TerminalTheme base) {
    Color pick(String? value, Color fallback) {
      final color = _toColor(value);
      return color ?? fallback;
    }

    Color ansiAt(int index, Color fallback) => pick(ansi[index], fallback);

    return TerminalTheme(
      cursor: pick(cursor, base.cursor),
      selection: pick(selectionBackground, base.selection),
      foreground: pick(foreground, base.foreground),
      background: pick(background, base.background),
      black: ansiAt(0, base.black),
      red: ansiAt(1, base.red),
      green: ansiAt(2, base.green),
      yellow: ansiAt(3, base.yellow),
      blue: ansiAt(4, base.blue),
      magenta: ansiAt(5, base.magenta),
      cyan: ansiAt(6, base.cyan),
      white: ansiAt(7, base.white),
      brightBlack: ansiAt(8, base.brightBlack),
      brightRed: ansiAt(9, base.brightRed),
      brightGreen: ansiAt(10, base.brightGreen),
      brightYellow: ansiAt(11, base.brightYellow),
      brightBlue: ansiAt(12, base.brightBlue),
      brightMagenta: ansiAt(13, base.brightMagenta),
      brightCyan: ansiAt(14, base.brightCyan),
      brightWhite: ansiAt(15, base.brightWhite),
      // Search highlight colours are ours, not the imported theme's — no
      // external format carries them.
      searchHitBackground: base.searchHitBackground,
      searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
      searchHitForeground: base.searchHitForeground,
    );
  }

  static Color? _toColor(String? value) {
    final normalized = normalizeHexColor(value);
    if (normalized == null) return null;
    final rgb = int.tryParse(normalized.substring(1), radix: 16);
    return rgb == null ? null : Color(0xFF000000 | rgb);
  }
}
