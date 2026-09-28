import 'terminal_palette.dart';

/// A named terminal colour scheme the user can pick: either **Match app**
/// ([palette] null — the app's own surface, text and accent around a fixed
/// ANSI set for its light or dark mode) or a fixed [palette] copied from a
/// published theme.
class TerminalScheme {
  const TerminalScheme({required this.id, required this.name, this.palette});

  /// Stored in settings as `preset:<id>`. Never change one: a renamed id
  /// silently puts everyone who chose it back on Match app.
  final String id;

  /// The theme's own name; a proper noun, so not translated.
  final String name;

  /// Null for Match app.
  final TerminalPalette? palette;

  bool get matchesApp => palette == null;

  /// Whether this scheme is drawn on a light ground; null for Match app,
  /// which follows the app.
  bool? get isLight => palette?.isLight;
}

/// Every built-in scheme, and how one is named in settings.
///
/// The fixed palettes were ported from the sibling PopupBits app SSHetu
/// (`lib/core/theme/terminal_theme_presets.dart`), which copied each from the
/// theme's own published source; the citations travel with them, so a
/// correction is a comparison against one file rather than an argument about
/// taste. Colour literals are data here: programs address them by index.
abstract final class TerminalSchemes {
  /// Match app's id — and what a missing or unknown id resolves to.
  static const matchAppId = 'match-app';

  /// The settings value (`terminalThemeSource`) that names a built-in scheme
  /// starts with this; a Ghostty or Warp file is `ghostty:` / `warp:`, and
  /// Match app is stored as no value at all, as "Built-in" always was.
  static const sourcePrefix = 'preset:';

  static const matchApp = TerminalScheme(id: matchAppId, name: 'Match app');

  /// The settings value for [scheme]: null for Match app.
  static String? sourceFor(TerminalScheme scheme) =>
      scheme.matchesApp ? null : '$sourcePrefix${scheme.id}';

  /// Whether [source] names a built-in scheme (known to this build or not).
  static bool isSchemeSource(String? source) =>
      source != null && source.startsWith(sourcePrefix);

  /// The scheme a stored settings value names; Match app for null, for an
  /// imported file's reference and for an id this build does not ship (a
  /// settings file written by a newer build).
  static TerminalScheme fromSource(String? source) {
    if (!isSchemeSource(source)) return matchApp;
    return byId(source!.substring(sourcePrefix.length));
  }

  /// The scheme for [id]; Match app for null or anything unknown.
  static TerminalScheme byId(String? id) =>
      all.where((s) => s.id == id).firstOrNull ?? matchApp;

  /// Match app's sixteen ANSI colours for a dark or a light ground. Only the
  /// ANSI slots: the app supplies background, text, cursor and selection.
  ///
  /// Fixed, and not derived from the accent: programs address them by meaning
  /// (red is an error, green a pass). Close to One Dark / One Light, tuned for
  /// contrast on each ground — the light set is darker and more saturated,
  /// because the hues that read on black wash out on white, and its "white"
  /// slots are greys, so text a program prints in white stays legible.
  static TerminalPalette matchAppAnsi({required bool dark}) =>
      dark ? _matchAppDark : _matchAppLight;

  static const _matchAppDark = TerminalPalette(
    ansi: {
      0: '#3f4451', // black
      1: '#e06c75', // red
      2: '#98c379', // green
      3: '#e5c07b', // yellow
      4: '#61afef', // blue
      5: '#c678dd', // magenta
      6: '#56b6c2', // cyan
      7: '#abb2bf', // white
      8: '#5c6370', // bright black
      9: '#ff7a85', // bright red
      10: '#b5e890', // bright green
      11: '#f5d08a', // bright yellow
      12: '#7fc4ff', // bright blue
      13: '#da8ff0', // bright magenta
      14: '#68cbd8', // bright cyan
      15: '#e6e6e6', // bright white
    },
  );

  static const _matchAppLight = TerminalPalette(
    ansi: {
      0: '#383a42', // black
      1: '#ca1243', // red
      2: '#3f7f2f', // green
      3: '#9a6800', // yellow
      4: '#0184bc', // blue
      5: '#a626a4', // magenta
      6: '#0997b3', // cyan
      7: '#6a737d', // white
      8: '#57606a', // bright black
      9: '#e4506b', // bright red
      10: '#2f6f1f', // bright green
      11: '#7a5300', // bright yellow
      12: '#0166a6', // bright blue
      13: '#8b1d8a', // bright magenta
      14: '#077d96', // bright cyan
      15: '#24292f', // bright white
    },
  );

  /// Source: Dracula's own Alacritty port, which carries the spec's terminal
  /// colours — https://github.com/dracula/alacritty/blob/master/dracula.toml
  /// (see also https://draculatheme.com/spec).
  static const dracula = TerminalScheme(
    id: 'dracula',
    name: 'Dracula',
    palette: TerminalPalette(
      foreground: '#f8f8f2',
      background: '#282a36',
      cursor: '#f8f8f2',
      selectionBackground: '#44475a',
      ansi: {
        0: '#21222c',
        1: '#ff5555',
        2: '#50fa7b',
        3: '#f1fa8c',
        4: '#bd93f9',
        5: '#ff79c6',
        6: '#8be9fd',
        7: '#f8f8f2',
        8: '#6272a4',
        9: '#ff6e6e',
        10: '#69ff94',
        11: '#ffffa5',
        12: '#d6acff',
        13: '#ff92df',
        14: '#a4ffff',
        15: '#ffffff',
      },
    ),
  );

  /// Source: Nord's official Xresources port, which maps the sixteen ANSI
  /// slots onto nord0–nord15 —
  /// https://github.com/nordtheme/xresources/blob/develop/src/nord.
  /// Selection is nord2, which Nord's docs name for selection highlights.
  static const nord = TerminalScheme(
    id: 'nord',
    name: 'Nord',
    palette: TerminalPalette(
      foreground: '#d8dee9', // nord4
      background: '#2e3440', // nord0
      cursor: '#d8dee9', // nord4
      selectionBackground: '#434c5e', // nord2
      ansi: {
        0: '#3b4252', // nord1
        1: '#bf616a', // nord11
        2: '#a3be8c', // nord14
        3: '#ebcb8b', // nord13
        4: '#81a1c1', // nord9
        5: '#b48ead', // nord15
        6: '#88c0d0', // nord8
        7: '#e5e9f0', // nord5
        8: '#4c566a', // nord3
        9: '#bf616a', // nord11
        10: '#a3be8c', // nord14
        11: '#ebcb8b', // nord13
        12: '#81a1c1', // nord9
        13: '#b48ead', // nord15
        14: '#8fbcbb', // nord7
        15: '#eceff4', // nord6
      },
    ),
  );

  /// Solarized's sixteen ANSI slots, shared by both variants — the table in
  /// https://github.com/altercation/solarized/blob/master/README.md
  /// (https://ethanschoonover.com/solarized/): black base02, white base2,
  /// bright black base03, bright green/yellow/blue/cyan base01/base00/base0/
  /// base1, bright red orange, bright magenta violet, bright white base3.
  static const _solarizedAnsi = <int, String>{
    0: '#073642', // base02
    1: '#dc322f', // red
    2: '#859900', // green
    3: '#b58900', // yellow
    4: '#268bd2', // blue
    5: '#d33682', // magenta
    6: '#2aa198', // cyan
    7: '#eee8d5', // base2
    8: '#002b36', // base03
    9: '#cb4b16', // orange
    10: '#586e75', // base01
    11: '#657b83', // base00
    12: '#839496', // base0
    13: '#6c71c4', // violet
    14: '#93a1a1', // base1
    15: '#fdf6e3', // base3
  };

  /// Source: as [_solarizedAnsi]. Body text base0 on base03, as the README
  /// specifies for the dark mode.
  static const solarizedDark = TerminalScheme(
    id: 'solarized-dark',
    name: 'Solarized Dark',
    palette: TerminalPalette(
      foreground: '#839496', // base0
      background: '#002b36', // base03
      cursor: '#93a1a1', // base1
      selectionBackground: '#073642', // base02
      ansi: _solarizedAnsi,
    ),
  );

  /// Source: as [_solarizedAnsi], with one deliberate departure. The README
  /// sets light-mode body text in base00 (#657B83), 4.1:1 against base3 —
  /// under WCAG's 4.5:1 for body text, and a terminal is nothing but body
  /// text. This uses base01 (#586E75, 5.0:1), the next step of the same ramp.
  static const solarizedLight = TerminalScheme(
    id: 'solarized-light',
    name: 'Solarized Light',
    palette: TerminalPalette(
      foreground: '#586e75', // base01, see above
      background: '#fdf6e3', // base3
      cursor: '#586e75', // base01
      selectionBackground: '#eee8d5', // base2
      ansi: _solarizedAnsi,
    ),
  );

  /// Source: the gruvbox palette, https://github.com/morhetz/gruvbox (README
  /// palette and `colors/gruvbox.vim`), dark mode with medium contrast.
  /// Selection is bg3 (#665C54), gruvbox's selection grey.
  static const gruvboxDark = TerminalScheme(
    id: 'gruvbox-dark',
    name: 'Gruvbox Dark',
    palette: TerminalPalette(
      foreground: '#ebdbb2', // fg / light1
      background: '#282828', // bg / dark0
      cursor: '#ebdbb2',
      selectionBackground: '#665c54', // bg3
      ansi: {
        0: '#282828',
        1: '#cc241d',
        2: '#98971a',
        3: '#d79921',
        4: '#458588',
        5: '#b16286',
        6: '#689d6a',
        7: '#a89984',
        8: '#928374',
        9: '#fb4934',
        10: '#b8bb26',
        11: '#fabd2f',
        12: '#83a598',
        13: '#d3869b',
        14: '#8ec07c',
        15: '#ebdbb2',
      },
    ),
  );

  /// Source: the "night" variant as shipped for terminals by the theme's
  /// author —
  /// https://github.com/folke/tokyonight.nvim/blob/main/extras/kitty/tokyonight_night.conf
  static const tokyoNight = TerminalScheme(
    id: 'tokyo-night',
    name: 'Tokyo Night',
    palette: TerminalPalette(
      foreground: '#c0caf5',
      background: '#1a1b26',
      cursor: '#c0caf5',
      selectionBackground: '#283457',
      ansi: {
        0: '#15161e',
        1: '#f7768e',
        2: '#9ece6a',
        3: '#e0af68',
        4: '#7aa2f7',
        5: '#bb9af7',
        6: '#7dcfff',
        7: '#a9b1d6',
        8: '#414868',
        9: '#ff899d',
        10: '#9fe044',
        11: '#faba4a',
        12: '#8db0ff',
        13: '#c7a9ff',
        14: '#a4daff',
        15: '#c0caf5',
      },
    ),
  );

  /// Source: Atom's One Dark defines no terminal, so the chrome is Atom's own
  /// — background, text, cursor (`@syntax-accent`) and selection
  /// (`lighten(@syntax-bg, 10%)`) from
  /// https://github.com/atom/atom/tree/master/packages/one-dark-syntax/styles
  /// — and the sixteen ANSI colours are Zed's One Dark terminal, the
  /// maintained port of the same palette:
  /// https://github.com/zed-industries/zed/blob/main/assets/themes/one/one.json
  static const oneDark = TerminalScheme(
    id: 'one-dark',
    name: 'One Dark',
    palette: TerminalPalette(
      foreground: '#abb2bf',
      background: '#282c34',
      cursor: '#528bff',
      selectionBackground: '#3e4451',
      ansi: {
        0: '#282c34',
        1: '#e06c75',
        2: '#98c379',
        3: '#e5c07b',
        4: '#61afef',
        5: '#c678dd',
        6: '#56b6c2',
        7: '#abb2bf',
        8: '#636d83',
        9: '#ea858b',
        10: '#aad581',
        11: '#ffd885',
        12: '#85c1ff',
        13: '#d398eb',
        14: '#6ed5de',
        15: '#fafafa',
      },
    ),
  );

  /// Source: Monokai (Wimer Hazenberg) as specified for base16 —
  /// https://github.com/tinted-theming/schemes/blob/spec-0.11/base16/monokai.yaml
  /// — mapped onto the ANSI slots the way base16-shell does (base00, 08, 0B,
  /// 0A, 0D, 0E, 0C, 05; base03; the same six hues; base07). The original
  /// Monokai is an editor theme with no terminal colours of its own.
  static const monokai = TerminalScheme(
    id: 'monokai',
    name: 'Monokai',
    palette: TerminalPalette(
      foreground: '#f8f8f2', // base05
      background: '#272822', // base00
      cursor: '#f8f8f2', // base05
      selectionBackground: '#49483e', // base02
      ansi: {
        0: '#272822', // base00
        1: '#f92672', // base08
        2: '#a6e22e', // base0B
        3: '#f4bf75', // base0A
        4: '#66d9ef', // base0D
        5: '#ae81ff', // base0E
        6: '#a1efe4', // base0C
        7: '#f8f8f2', // base05
        8: '#75715e', // base03
        9: '#f92672', // base08
        10: '#a6e22e', // base0B
        11: '#f4bf75', // base0A
        12: '#66d9ef', // base0D
        13: '#ae81ff', // base0E
        14: '#a1efe4', // base0C
        15: '#f9f8f5', // base07
      },
    ),
  );

  /// In the order the picker shows them: Match app first.
  static const List<TerminalScheme> all = [
    matchApp,
    dracula,
    nord,
    solarizedDark,
    solarizedLight,
    gruvboxDark,
    tokyoNight,
    oneDark,
    monokai,
  ];
}
