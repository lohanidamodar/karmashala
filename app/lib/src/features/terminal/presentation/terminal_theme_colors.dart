/// The terminal's colours. Read from outside the panel — the recording dialog
/// renders a cast in the colours the pane had, Settings previews each scheme —
/// and re-exported by `terminal_panel.dart`.
library;

import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:xterm2/xterm.dart';

import 'package:karmashala_terminal_core/grid.dart';

/// The terminal's colours under [theme], with [palette] — a built-in scheme's
/// or an imported file's — layered over **Match app**:
///
///  * the ground is the `term` surface, so the pane reads as one piece with
///    the tab it sits in; the text is the app's, the cursor its accent, and a
///    selection a tint of the accent that reads on either ground;
///  * the sixteen ANSI colours are a fixed set tuned for the ground they sit
///    on — for a palette with its own background, *that* ground's lightness,
///    not the app's, so a half-filled light theme is not topped up with
///    colours made for black.
///
/// A palette's own colours win: they were picked deliberately.
TerminalTheme terminalThemeFor(ThemeData theme, TerminalPalette? palette) {
  final scheme = theme.colorScheme;
  final term =
      theme.extension<SurfaceTones>()?.term ?? scheme.surfaceContainerLowest;
  final lightGround = palette?.isLight ?? theme.brightness == Brightness.light;
  final base = TerminalSchemes.matchAppAnsi(dark: !lightGround)
      .applyTo(TerminalThemes.defaultTheme)
      .copyWith(
        background: term,
        foreground: scheme.onSurface,
        cursor: scheme.primary,
        // Painted under the glyphs, so a translucent tint keeps them legible.
        selection: StateLayers.textSelection(scheme),
      );
  return palette?.applyTo(base) ?? base;
}

extension on TerminalTheme {
  TerminalTheme copyWith({
    Color? background,
    Color? foreground,
    Color? cursor,
    Color? selection,
  }) {
    return TerminalTheme(
      cursor: cursor ?? this.cursor,
      selection: selection ?? this.selection,
      foreground: foreground ?? this.foreground,
      background: background ?? this.background,
      black: black,
      red: red,
      green: green,
      yellow: yellow,
      blue: blue,
      magenta: magenta,
      cyan: cyan,
      white: white,
      brightBlack: brightBlack,
      brightRed: brightRed,
      brightGreen: brightGreen,
      brightYellow: brightYellow,
      brightBlue: brightBlue,
      brightMagenta: brightMagenta,
      brightCyan: brightCyan,
      brightWhite: brightWhite,
      searchHitBackground: searchHitBackground,
      searchHitBackgroundCurrent: searchHitBackgroundCurrent,
      searchHitForeground: searchHitForeground,
    );
  }
}
