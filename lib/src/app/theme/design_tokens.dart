import 'package:flutter/material.dart';

/// Design tokens for Chitragupta's desktop chrome.
///
/// **Neutral by decision** (see `docs/superpowers/specs/`
/// `2026-08-30-desktop-ui-direction.md`). The ink / brass / parchment identity
/// is retired: a greyscale ramp carries the chrome, a single accent marks
/// selection and focus, and colour that means something is reserved for
/// [SemanticColors]. The app sits beside a terminal painted in the user's own
/// imported theme, so the chrome must not compete with it.
class AppColors {
  const AppColors._();

  // ---------------------------------------------------------------------
  // Neutral surface ramp — light
  // ---------------------------------------------------------------------
  static const lightLowest = Color(0xFFFFFFFF);
  static const lightSurface = Color(0xFFF7F7F8);
  static const lightLow = Color(0xFFF2F2F4);
  static const lightContainer = Color(0xFFECECEF);
  static const lightHigh = Color(0xFFE4E4E8);
  static const lightHighest = Color(0xFFDBDBE1);
  static const lightOn = Color(0xFF1B1B1F);
  static const lightOnVariant = Color(0xFF56565F);
  static const lightOutline = Color(0xFF8C8C96);
  static const lightOutlineVariant = Color(0xFFD5D5DC);

  // ---------------------------------------------------------------------
  // Neutral surface ramp — dark
  // ---------------------------------------------------------------------
  static const darkLowest = Color(0xFF0E0E11);
  static const darkSurface = Color(0xFF141417);
  static const darkLow = Color(0xFF1A1A1E);
  static const darkContainer = Color(0xFF1F1F24);
  static const darkHigh = Color(0xFF26262C);
  static const darkHighest = Color(0xFF2E2E35);
  static const darkOn = Color(0xFFE4E4E9);
  static const darkOnVariant = Color(0xFF9E9EA9);
  static const darkOutline = Color(0xFF6A6A75);
  static const darkOutlineVariant = Color(0xFF33333B);

  /// The one accent. Selection, focus, the primary action — nothing else.
  static const accentLight = Color(0xFF2F6FE0);
  static const accentDark = Color(0xFF7AA2F7);

  static const dangerLight = Color(0xFFB3261E);
  static const dangerDark = Color(0xFFFF9D96);
}

/// Colour that carries meaning, not identity.
///
/// Agent status, diff hunks and warnings are the only things allowed to be
/// coloured outside the accent; everything else lives on the neutral ramp. Kept
/// as a [ThemeExtension] so light and dark resolve through `Theme.of` like any
/// other themed value, and so a widget can never reach for a raw `Colors.green`.
@immutable
class SemanticColors extends ThemeExtension<SemanticColors> {
  const SemanticColors({
    required this.working,
    required this.idle,
    required this.attention,
    required this.failure,
    required this.diffAdded,
    required this.diffRemoved,
    required this.neutral,
  });

  /// An agent is mid-turn.
  final Color working;

  /// An agent finished and is waiting for input; also plain "healthy".
  final Color idle;

  /// The user is being asked for something — approval, a decision, a warning.
  final Color attention;

  /// A run failed. Distinct from [ColorScheme.error], which also styles form
  /// validation; kept separate so status never borrows form chrome.
  final Color failure;

  final Color diffAdded;
  final Color diffRemoved;

  /// "We could not tell" — an absence of signal, not a bad one.
  final Color neutral;

  static const _light = SemanticColors(
    working: Color(0xFF0E6E90),
    idle: Color(0xFF1F7A3D),
    attention: Color(0xFF9A5B00),
    failure: Color(0xFFB3261E),
    diffAdded: Color(0xFF1A7F37),
    diffRemoved: Color(0xFFB92534),
    neutral: Color(0xFF7C7C86),
  );

  static const _dark = SemanticColors(
    working: Color(0xFF56C0E8),
    idle: Color(0xFF6BCF87),
    attention: Color(0xFFE8B44A),
    failure: Color(0xFFFF8A82),
    diffAdded: Color(0xFF57C97A),
    diffRemoved: Color(0xFFF07C86),
    neutral: Color(0xFF8E8E99),
  );

  static SemanticColors of(BuildContext context) =>
      Theme.of(context).extension<SemanticColors>() ?? _light;

  static SemanticColors forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  @override
  SemanticColors copyWith({
    Color? working,
    Color? idle,
    Color? attention,
    Color? failure,
    Color? diffAdded,
    Color? diffRemoved,
    Color? neutral,
  }) {
    return SemanticColors(
      working: working ?? this.working,
      idle: idle ?? this.idle,
      attention: attention ?? this.attention,
      failure: failure ?? this.failure,
      diffAdded: diffAdded ?? this.diffAdded,
      diffRemoved: diffRemoved ?? this.diffRemoved,
      neutral: neutral ?? this.neutral,
    );
  }

  @override
  SemanticColors lerp(ThemeExtension<SemanticColors>? other, double t) {
    if (other is! SemanticColors) return this;
    return SemanticColors(
      working: Color.lerp(working, other.working, t)!,
      idle: Color.lerp(idle, other.idle, t)!,
      attention: Color.lerp(attention, other.attention, t)!,
      failure: Color.lerp(failure, other.failure, t)!,
      diffAdded: Color.lerp(diffAdded, other.diffAdded, t)!,
      diffRemoved: Color.lerp(diffRemoved, other.diffRemoved, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
    );
  }
}

/// Spacing scale (4-pt base). Use these instead of ad-hoc paddings.
class Insets {
  const Insets._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Corner radii.
class Radii {
  const Radii._();
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
  static const Radius card = Radius.circular(md);
}

/// Motion durations.
class Motion {
  const Motion._();
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 220);
}

/// Fixed heights for the desktop chrome, in logical pixels.
///
/// Sized for a mouse: a pointer hits a 28px row reliably, and every pixel spent
/// on chrome is a pixel taken from the terminal. Collected here so the title
/// bar, the workbench tab strip, the side-panel rail and the status bar stay in
/// proportion to one another instead of drifting apart file by file.
class Chrome {
  const Chrome._();

  /// The menu-bar row at the top of the window.
  static const titleBar = 32.0;

  /// The workbench tab strip and the side panel's header.
  static const tabStrip = 30.0;

  /// The status bar along the bottom of the window.
  static const statusBar = 22.0;

  /// The side panel's icon rail — the only chrome the panel keeps when closed.
  static const rail = 34.0;

  /// A dense list row (explorer tree, palette results).
  static const row = 26.0;

  /// Icon sizes: [icon] in toolbars, [iconSmall] inline with text.
  static const icon = 16.0;
  static const iconSmall = 13.0;
}

/// A monospace stack for the "ledger hand" — paths, ids, event types, diffs.
const String kMonoFamily = 'monospace';
