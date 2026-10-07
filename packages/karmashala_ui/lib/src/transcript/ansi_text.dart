import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Text with ANSI SGR colour and weight, as a terminal would draw it. Every
/// other escape — cursor moves, titles, hyperlinks — is dropped, never shown.
class AnsiText extends StatelessWidget {
  const AnsiText(this.source, {this.style, this.softWrap = true, super.key});

  final String source;
  final TextStyle? style;
  final bool softWrap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        style ?? MonoStyles.small.copyWith(color: theme.colorScheme.onSurface);
    return Text.rich(
      ansiSpan(source, base: base, palette: AnsiPalette.of(theme.brightness)),
      softWrap: softWrap,
    );
  }
}

/// Whether [text] carries any escape sequence at all.
bool hasAnsi(String text) => text.contains('\x1B');

/// [text] without any escape sequence: what Copy puts down.
String stripAnsi(String text) => text.replaceAll(_escape, '');

final _escape = RegExp(
  r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
);

/// [text] as spans, each styled by the SGR state in force where it starts.
TextSpan ansiSpan(
  String text, {
  required TextStyle base,
  required List<Color> palette,
}) {
  final spans = <TextSpan>[];
  var state = const _Sgr();
  var cursor = 0;
  for (final match in _escape.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(
        TextSpan(
          text: text.substring(cursor, match.start),
          style: state.style(palette),
        ),
      );
    }
    final escape = match[0]!;
    if (escape.startsWith('\x1B[') && escape.endsWith('m')) {
      state = state.apply(escape.substring(2, escape.length - 1));
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(
      TextSpan(text: text.substring(cursor), style: state.style(palette)),
    );
  }
  return TextSpan(style: base, children: spans);
}

class _Sgr {
  const _Sgr({
    this.fg,
    this.bg,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
  });

  /// A palette index (0–255) or an RGB colour.
  final Object? fg;
  final Object? bg;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;

  _Sgr copy({
    Object? fg = _keep,
    Object? bg = _keep,
    bool? bold,
    bool? dim,
    bool? italic,
    bool? underline,
  }) => _Sgr(
    fg: identical(fg, _keep) ? this.fg : fg,
    bg: identical(bg, _keep) ? this.bg : bg,
    bold: bold ?? this.bold,
    dim: dim ?? this.dim,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
  );

  _Sgr apply(String params) {
    final codes = params.isEmpty
        ? const [0]
        : [for (final p in params.split(';')) int.tryParse(p) ?? 0];
    var s = this;
    for (var i = 0; i < codes.length; i++) {
      final c = codes[i];
      switch (c) {
        case 0:
          s = const _Sgr();
        case 1:
          s = s.copy(bold: true);
        case 2:
          s = s.copy(dim: true);
        case 3:
          s = s.copy(italic: true);
        case 4:
          s = s.copy(underline: true);
        case 22:
          s = s.copy(bold: false, dim: false);
        case 23:
          s = s.copy(italic: false);
        case 24:
          s = s.copy(underline: false);
        case >= 30 && <= 37:
          s = s.copy(fg: c - 30);
        case >= 90 && <= 97:
          s = s.copy(fg: c - 90 + 8);
        case 39:
          s = s.copy(fg: null);
        case >= 40 && <= 47:
          s = s.copy(bg: c - 40);
        case >= 100 && <= 107:
          s = s.copy(bg: c - 100 + 8);
        case 49:
          s = s.copy(bg: null);
        case 38 || 48:
          final (color, used) = _extended(codes, i + 1);
          s = c == 38 ? s.copy(fg: color) : s.copy(bg: color);
          i += used;
      }
    }
    return s;
  }

  static (Object?, int) _extended(List<int> codes, int at) {
    if (at >= codes.length) return (null, 0);
    if (codes[at] == 5 && at + 1 < codes.length) return (codes[at + 1], 2);
    if (codes[at] == 2 && at + 3 < codes.length) {
      return (_rgb(codes[at + 1], codes[at + 2], codes[at + 3]), 4);
    }
    return (null, 0);
  }

  TextStyle? style(List<Color> palette) {
    if (fg == null && bg == null && !bold && !dim && !italic && !underline) {
      return null;
    }
    var color = _resolve(fg, palette);
    if (dim && color != null) color = color.withValues(alpha: 0.6);
    return TextStyle(
      color: color,
      backgroundColor: _resolve(bg, palette),
      fontWeight: bold ? FontWeight.w700 : null,
      fontStyle: italic ? FontStyle.italic : null,
      decoration: underline ? TextDecoration.underline : null,
    );
  }

  static Color? _resolve(Object? value, List<Color> palette) => switch (value) {
    final Color color => color,
    final int index when index < 16 => palette[index],
    final int index when index < 232 => _cube(index - 16),
    final int index when index < 256 => _grey(index - 232),
    _ => null,
  };

  static Color _cube(int i) {
    int level(int v) => v == 0 ? 0 : 55 + v * 40;
    return _rgb(level(i ~/ 36), level(i ~/ 6 % 6), level(i % 6));
  }

  static Color _grey(int i) {
    final v = 8 + i * 10;
    return _rgb(v, v, v);
  }
}

const Object _keep = Object();

/// An opaque colour from 0–255 channels, as SGR's 24-bit form gives them.
Color _rgb(int r, int g, int b) => Color(
  0xFF000000 |
      (r.clamp(0, 255) << 16) |
      (g.clamp(0, 255) << 8) |
      b.clamp(0, 255),
);
