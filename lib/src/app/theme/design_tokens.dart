import 'package:flutter/material.dart';

/// Design tokens for Karmashala's desktop chrome.
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
  static const darkSurface = Color(0xFF17171B);
  static const darkLow = Color(0xFF1F1F24);
  static const darkContainer = Color(0xFF25252B);
  static const darkHigh = Color(0xFF2C2C33);
  static const darkHighest = Color(0xFF35353D);
  static const darkOn = Color(0xFFE4E4E9);
  static const darkOnVariant = Color(0xFF9E9EA9);
  static const darkOutline = Color(0xFF6A6A75);
  static const darkOutlineVariant = Color(0xFF35353E);

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

  /// A bottom sheet's top corners — the one radius a pointer surface never
  /// draws, because it has no bottom sheets.
  static const sheet = 22.0;

  static const Radius card = Radius.circular(md);
}

/// What a finger needs, where [Chrome] says what a pointer needs.
class Touch {
  const Touch._();

  /// The floor for anything tappable, in logical pixels. Material and the
  /// accessibility guidelines agree on 48; a 26px [Chrome.row] is a miss.
  static const target = 48.0;

  /// The least space between two targets, so a thumb cannot hit both.
  static const gap = Insets.sm;

  /// A leading glyph on a touch row, and the same glyph inside a dense clause.
  static const icon = 18.0;
  static const iconSmall = 14.0;

  /// A touch surface's app bar, at the default text scale.
  static const appBar = 56.0;

  /// [appBar] grown with the ambient text scale and never shrunk below the
  /// design height — a 200% title does not fit 56px, and the screen's own name
  /// is the worst thing to clip.
  static double appBarOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(appBar).clamp(appBar, 96.0);
}

/// How dense the *shared* cards and rows draw themselves.
///
/// The Explorer's `SessionCard` and `ProjectCard` are the same widgets on the
/// desktop and on the phone — one design language, adapted rather than forked.
/// What differs between a mouse and a thumb is spacing, hit area and one step
/// of the type ramp, and that is one decision, taken once, here.
///
/// **Read from a [UiDensityScope], not from the ambient width.** The Explorer
/// pane is routinely narrower than the compact breakpoint on a 1440px desktop,
/// and a widget test hosts a card in a 300px box; inferring density from
/// whatever `MediaQuery` reports would make both of those touch surfaces. The
/// root that *knows* what it is — the companion app — installs the scope,
/// computing it from its own width via [UiDensity.forWidth]. Anything with no
/// scope above it is [UiDensity.pointer], which is exactly what the desktop
/// has always drawn.
enum UiDensity {
  /// A mouse aims: dense rows, 11–13px glyphs, no target floor.
  pointer,

  /// A thumb does not: 48dp targets, roomier padding, one step up the ramp.
  touch;

  /// The Material compact breakpoint (CLAUDE.md §6).
  static const compactWidth = 600.0;

  /// The density a surface [width] logical pixels wide calls for.
  static UiDensity forWidth(double width) =>
      width < compactWidth ? UiDensity.touch : UiDensity.pointer;

  /// The density in effect for [context]; [UiDensity.pointer] with no scope.
  static UiDensity of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UiDensityScope>()
          ?.density ??
      UiDensity.pointer;

  bool get isTouch => this == UiDensity.touch;

  /// Horizontal and vertical padding inside a card or row.
  double get padX => isTouch ? Insets.lg : 6;
  double get padY => isTouch ? Insets.md : 6;

  /// Between two lines of the same card.
  double get lineGap => isTouch ? Insets.xs : 2;

  /// Between a glyph and the word it labels.
  double get glyphGap => isTouch ? 6 : 4;

  /// A leading glyph beside a card's own text.
  double get icon => isTouch ? Touch.icon : Chrome.iconSmall;

  /// A glyph inside a dense clause — a worktree mark, a lineage warning.
  double get iconSmall => isTouch ? Touch.iconSmall : 11;

  /// The floor for a tappable row. Zero on a pointer surface, where the
  /// Explorer's density is the point.
  double get minRow => isTouch ? Touch.target : 0;

  /// The strongest line on a card — a session's title, a project's name.
  TextStyle? title(ThemeData theme) =>
      (isTouch ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)
          ?.copyWith(fontWeight: FontWeight.w600);

  /// The muted supporting lines. A phone steps up to `bodySmall` because 11px
  /// is under the floor for text a thumb's owner reads at arm's length.
  TextStyle? muted(ThemeData theme) =>
      (isTouch ? theme.textTheme.bodySmall : theme.textTheme.labelSmall)
          ?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0,
          );

  /// [base] re-tuned for this density: **identity** for [UiDensity.pointer],
  /// so the desktop keeps the theme it has always had.
  ///
  /// Everything here is a size, not a colour or a font — the two platforms
  /// share one palette and one type ramp, and differ only in how much room a
  /// finger needs. Material's own `visualDensity: compact` and `shrinkWrap`
  /// tap targets are the first things undone: they shrink every button in the
  /// app below the 48dp floor.
  ThemeData themeFor(ThemeData base) {
    if (!isTouch) return base;
    final scheme = base.colorScheme;
    final text = base.textTheme;
    ButtonStyle grow(ButtonStyle? style) =>
        (style ?? const ButtonStyle()).copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(0, Touch.target)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: Insets.xl),
          ),
          textStyle: WidgetStatePropertyAll(text.bodyMedium),
        );

    return base.copyWith(
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      appBarTheme: base.appBarTheme.copyWith(
        toolbarHeight: Touch.appBar,
        backgroundColor: scheme.surface,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(
          size: Touch.icon + 2,
          color: scheme.onSurfaceVariant,
        ),
        actionsIconTheme: IconThemeData(
          size: Touch.icon + 2,
          color: scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: base.iconTheme.copyWith(size: Touch.icon),
      filledButtonTheme: FilledButtonThemeData(
        style: grow(base.filledButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: grow(base.outlinedButtonTheme.style),
      ),
      textButtonTheme: TextButtonThemeData(
        style: grow(base.textButtonTheme.style),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(Touch.target),
          iconSize: Touch.icon + 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
        ),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.xs,
        ),
        minVerticalPadding: Insets.md,
        horizontalTitleGap: Insets.md,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodySmall,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        isDense: false,
        contentPadding: const EdgeInsets.all(Insets.md),
        helperMaxLines: 3,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Radii.sheet),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      dialogTheme: base.dialogTheme.copyWith(
        insetPadding: const EdgeInsets.all(Insets.xl),
      ),
    );
  }

  /// Installs the density for [child] — computed from the ambient width, so a
  /// phone in a fold-out or a tablet in landscape gets the right one — and
  /// re-tunes the inherited theme to match.
  ///
  /// The one call a root makes; nothing below it decides for itself.
  static Widget wrap(BuildContext context, Widget child) {
    final density = UiDensity.forWidth(MediaQuery.sizeOf(context).width);
    return UiDensityScope(
      density: density,
      child: Theme(data: density.themeFor(Theme.of(context)), child: child),
    );
  }
}

/// Declares the [UiDensity] for everything below it.
class UiDensityScope extends InheritedWidget {
  const UiDensityScope({
    required this.density,
    required super.child,
    super.key,
  });

  final UiDensity density;

  @override
  bool updateShouldNotify(UiDensityScope oldWidget) =>
      oldWidget.density != density;
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

  /// The workbench tab strip, the side panel's header and every pane header.
  static const tabStrip = 30.0;

  /// The menu-bar row at the top of the window — deliberately *the same* row
  /// as [tabStrip]. It was 32 against everything else's 30, which is enough to
  /// see and not enough to look intended: the top-left of the window read as
  /// one undifferentiated slab of chrome rather than two rows.
  static const titleBar = tabStrip;

  /// The status bar along the bottom of the window.
  static const statusBar = 22.0;

  /// The side panel's icon rail — the only chrome the panel keeps when closed.
  static const rail = 34.0;

  /// A dense list row (explorer tree, palette results).
  static const row = 26.0;

  /// Icon sizes: [icon] in toolbars, [iconSmall] inline with text,
  /// [iconTitle] in a dialog's title row, where it sits against `titleMedium`
  /// rather than body text and a toolbar glyph reads as an afterthought.
  static const icon = 16.0;
  static const iconSmall = 13.0;
  static const iconTitle = 18.0;

  /// The label on a tab chip — the workbench strip's, and a region header's.
  ///
  /// Fixed rather than scaled, and named here for exactly that reason: a chip
  /// sits in a [tabStrip] row that does not grow, so a label that followed the
  /// text scaler would be clipped rather than read. A size still belongs in the
  /// theme layer when it is deliberately fixed — a widget must not be the place
  /// that decides one.
  static const TextStyle tabLabel = TextStyle(fontSize: 12);

  /// [titleBar] grown with the ambient text scale, and never shrunk below the
  /// design height: a 150% menu label does not fit a 30px row, and clipping
  /// the menu bar was exactly the "menus ignore text sizing" bug.
  static double titleBarOf(BuildContext context) => MediaQuery.textScalerOf(
    context,
  ).scale(titleBar).clamp(titleBar, 52.0);

  /// [statusBar], same treatment.
  static double statusBarOf(BuildContext context) => MediaQuery.textScalerOf(
    context,
  ).scale(statusBar).clamp(statusBar, 38.0);
}

/// A monospace stack for the "ledger hand" — paths, ids, event types, diffs.
const String kMonoFamily = 'monospace';

/// The ledger hand's text styles, in the theme layer where a size may be
/// named. Feature widgets use these instead of declaring their own
/// `fontSize:` (the token guard test enforces it), and because the size lives
/// on an ordinary [TextStyle] they follow the app's text scaler like any
/// other text.
class MonoStyles {
  const MonoStyles._();

  /// Inline identifiers beside label-sized text (chips, badges).
  static const TextStyle small = TextStyle(
    fontFamily: kMonoFamily,
    fontSize: 11,
  );

  /// The default ledger hand: paths, ids, environment names.
  static const TextStyle body = TextStyle(
    fontFamily: kMonoFamily,
    fontSize: 12,
  );

  /// A ledger value promoted to sit beside body text (a hotkey combo).
  static const TextStyle label = TextStyle(
    fontFamily: kMonoFamily,
    fontSize: 13,
  );
}
