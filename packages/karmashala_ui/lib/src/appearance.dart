import 'package:flutter/material.dart';

/// The accent the user picked (UI overhaul spec §3). Selection, focus and the
/// primary action wear it; status colours never do, whatever it is.
enum AppAccent {
  blue('Blue', Color(0xFF7AA2F7), Color(0xFF2F6FE0)),
  teal('Teal', Color(0xFF5FB3A1), Color(0xFF1F7A6A)),
  violet('Violet', Color(0xFFA98BE0), Color(0xFF6E4FC2)),
  rose('Rose', Color(0xFFE07A9A), Color(0xFFB83B63)),
  amber('Amber', Color(0xFFD9A45B), Color(0xFF9A6412));

  const AppAccent(this.label, this.onDark, this.onLight);

  final String label;

  /// On the dark ramp.
  final Color onDark;

  /// On the light ramp: darkened to keep 4.5:1 against its background.
  final Color onLight;

  Color forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? onDark : onLight;

  /// The accent stored under [name], or blue for one this build does not have.
  static AppAccent fromName(String? name) =>
      values.where((a) => a.name == name).firstOrNull ?? blue;
}

/// How regions are told apart: by surface tone alone, or with hairlines too.
enum SurfaceSeparation {
  tones('Tones'),
  borders('Borders');

  const SurfaceSeparation(this.label);

  final String label;

  static SurfaceSeparation fromName(String? name) =>
      values.where((s) => s.name == name).firstOrNull ?? tones;
}

/// Everything the user chose about the look, handed to `AppTheme` whole.
@immutable
class AppearanceOptions {
  const AppearanceOptions({
    this.accent = AppAccent.blue,
    this.separation = SurfaceSeparation.tones,
  });

  final AppAccent accent;
  final SurfaceSeparation separation;

  @override
  bool operator ==(Object other) =>
      other is AppearanceOptions &&
      other.accent == accent &&
      other.separation == separation;

  @override
  int get hashCode => Object.hash(accent, separation);
}

/// **The tone ladder** (spec §3): named surfaces for the shell's regions, so a
/// region asks for `chrome` rather than a hex or a Material role it has to
/// guess at. Regions are told apart by these tones; [line] is the structural
/// hairline, transparent under [SurfaceSeparation.tones].
@immutable
class SurfaceTones extends ThemeExtension<SurfaceTones> {
  const SurfaceTones({
    required this.strip,
    required this.side,
    required this.chrome,
    required this.panel,
    required this.term,
    required this.background,
    required this.raised,
    required this.selected,
    required this.pressed,
    required this.line,
    required this.floatingLine,
    required this.attentionSurface,
    required this.attentionEdge,
  });

  /// Title bar and activity strip: the darkest step.
  final Color strip;

  /// The sidebar.
  final Color side;

  /// Tab strip and pane status lines.
  final Color chrome;

  /// The context panel, and split panes that are not terminals.
  final Color panel;

  /// Terminal and chat, and the active tab.
  final Color term;

  /// The window behind everything.
  final Color background;

  /// Fields and cards on a region (`s1`).
  final Color raised;

  /// A selected row (`s2`).
  final Color selected;

  /// A pressed control, a track (`s3`).
  final Color pressed;

  /// The structural hairline between regions.
  final Color line;

  /// The hairline a floating surface keeps: menus, popovers, the quick panel.
  final Color floatingLine;

  /// Behind an ask that waits for the user, and its edge.
  final Color attentionSurface;
  final Color attentionEdge;

  static SurfaceTones of(BuildContext context) =>
      Theme.of(context).extension<SurfaceTones>() ??
      SurfaceTones.forBrightness(Theme.of(context).brightness);

  static SurfaceTones forBrightness(
    Brightness brightness, {
    SurfaceSeparation separation = SurfaceSeparation.tones,
  }) {
    final borders = separation == SurfaceSeparation.borders;
    if (brightness == Brightness.dark) {
      return SurfaceTones(
        strip: const Color(0xFF09090B),
        side: borders ? const Color(0xFF0E0E10) : const Color(0xFF121215),
        chrome: borders ? const Color(0xFF0E0E10) : const Color(0xFF141417),
        panel: borders ? const Color(0xFF0E0E10) : const Color(0xFF131316),
        term: const Color(0xFF0C0C0E),
        background: const Color(0xFF0E0E10),
        raised: const Color(0xFF17171B),
        selected: const Color(0xFF1F1F24),
        pressed: const Color(0xFF26262C),
        line: borders ? const Color(0xFF1D1D22) : const Color(0x00000000),
        floatingLine: const Color(0xFF26262C),
        attentionSurface: const Color(0xFF221B10),
        attentionEdge: const Color(0xFF4A3A1C),
      );
    }
    return SurfaceTones(
      strip: const Color(0xFFE8E8E4),
      side: borders ? const Color(0xFFFBFBFA) : const Color(0xFFF2F2EF),
      chrome: borders ? const Color(0xFFFBFBFA) : const Color(0xFFEEEEEB),
      panel: borders ? const Color(0xFFFBFBFA) : const Color(0xFFF5F5F3),
      term: const Color(0xFFFFFFFF),
      background: const Color(0xFFFBFBFA),
      raised: const Color(0xFFF1F1EF),
      selected: const Color(0xFFE9E9E6),
      pressed: const Color(0xFFDCDCD8),
      line: borders ? const Color(0xFFE6E6E3) : const Color(0x00FFFFFF),
      floatingLine: const Color(0xFFDCDCD8),
      attentionSurface: const Color(0xFFFBF1DD),
      attentionEdge: const Color(0xFFE6CB93),
    );
  }

  @override
  SurfaceTones copyWith({
    Color? strip,
    Color? side,
    Color? chrome,
    Color? panel,
    Color? term,
    Color? background,
    Color? raised,
    Color? selected,
    Color? pressed,
    Color? line,
    Color? floatingLine,
    Color? attentionSurface,
    Color? attentionEdge,
  }) => SurfaceTones(
    strip: strip ?? this.strip,
    side: side ?? this.side,
    chrome: chrome ?? this.chrome,
    panel: panel ?? this.panel,
    term: term ?? this.term,
    background: background ?? this.background,
    raised: raised ?? this.raised,
    selected: selected ?? this.selected,
    pressed: pressed ?? this.pressed,
    line: line ?? this.line,
    floatingLine: floatingLine ?? this.floatingLine,
    attentionSurface: attentionSurface ?? this.attentionSurface,
    attentionEdge: attentionEdge ?? this.attentionEdge,
  );

  // Value equality, so an equal theme rebuilt is the same theme: without it
  // every rebuild of a MaterialApp animated a "change" and remounted spinners.
  @override
  bool operator ==(Object other) =>
      other is SurfaceTones &&
      other.strip == strip &&
      other.side == side &&
      other.chrome == chrome &&
      other.panel == panel &&
      other.term == term &&
      other.background == background &&
      other.raised == raised &&
      other.selected == selected &&
      other.pressed == pressed &&
      other.line == line &&
      other.floatingLine == floatingLine &&
      other.attentionSurface == attentionSurface &&
      other.attentionEdge == attentionEdge;

  @override
  int get hashCode => Object.hash(
    strip,
    side,
    chrome,
    panel,
    term,
    background,
    raised,
    selected,
    pressed,
    line,
    floatingLine,
    attentionSurface,
    attentionEdge,
  );

  @override
  SurfaceTones lerp(covariant SurfaceTones? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return SurfaceTones(
      strip: mix(strip, other.strip),
      side: mix(side, other.side),
      chrome: mix(chrome, other.chrome),
      panel: mix(panel, other.panel),
      term: mix(term, other.term),
      background: mix(background, other.background),
      raised: mix(raised, other.raised),
      selected: mix(selected, other.selected),
      pressed: mix(pressed, other.pressed),
      line: mix(line, other.line),
      floatingLine: mix(floatingLine, other.floatingLine),
      attentionSurface: mix(attentionSurface, other.attentionSurface),
      attentionEdge: mix(attentionEdge, other.attentionEdge),
    );
  }
}
