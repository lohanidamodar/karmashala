import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Design tokens for Karmashala's desktop chrome. Neutral by decision: the app
/// sits beside a terminal in the user's own theme and must not compete with it.
class AppColors {
  const AppColors._();

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

/// Colour that carries meaning, not identity — agent status, diff hunks and
/// warnings only. A [ThemeExtension], so no widget reaches for `Colors.green`.
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
    required this.failureSurface,
    required this.workingSurface,
    required this.unread,
  });

  /// An agent is mid-turn: the accent, drawn as a spinner (spec §2.3). The
  /// theme sets it from the chosen accent through [withAccent]; the default is
  /// the default accent.
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

  /// Washes of the status hues, for a card or bar that carries that status.
  /// Translucent, so they sit on whichever surface holds them. The amber one
  /// is not here: an ask's rest is the spec's opaque
  /// `SurfaceTones.attentionSurface`, one source for every needs-you fill.
  final Color failureSurface;
  final Color workingSurface;

  /// A session finished while nobody was looking.
  final Color unread;

  /// The edge a status surface is drawn with, over its own hue.
  static const surfaceEdgeAlpha = 0.4;

  // Spec §3: warn E0A340 / B7791F, err E5534B / C9362E, ok 5FB37C / 2F8A4C.
  // The light warn and ok keep the spec's hue, darkened — as the spec darkens
  // the light accent — until words in them keep 4.5:1 on the sidebar: the
  // spec's own B7791F and 2F8A4C read 3.3:1 and 3.9:1 there.
  static const _lightAttention = Color(0xFF966319);
  static const _lightFailure = Color(0xFFC9362E);
  static const _lightIdle = Color(0xFF2A7C44);
  static const _lightWorking = AppColors.accentLight;
  static const _darkAttention = Color(0xFFE0A340);
  static const _darkFailure = Color(0xFFE5534B);
  static const _darkIdle = Color(0xFF5FB37C);
  static const _darkWorking = AppColors.accentDark;

  static final _light = SemanticColors(
    working: _lightWorking,
    idle: _lightIdle,
    attention: _lightAttention,
    failure: _lightFailure,
    diffAdded: const Color(0xFF1A7F37),
    diffRemoved: const Color(0xFFB92534),
    neutral: const Color(0xFF7C7C86),
    failureSurface: _lightFailure.withValues(alpha: 0.08),
    workingSurface: _lightWorking.withValues(alpha: _lightWash),
    unread: _lightIdle,
  );

  static final _dark = SemanticColors(
    working: _darkWorking,
    idle: _darkIdle,
    attention: _darkAttention,
    failure: _darkFailure,
    diffAdded: const Color(0xFF57C97A),
    diffRemoved: const Color(0xFFF07C86),
    neutral: const Color(0xFF8E8E99),
    failureSurface: _darkFailure.withValues(alpha: 0.16),
    workingSurface: _darkWorking.withValues(alpha: _darkWorkingWash),
    unread: _darkIdle,
  );

  static const _lightWash = 0.08;
  static const _darkWorkingWash = 0.14;

  /// These colours with "working" in [accent] — the theme's chosen accent, so
  /// the spinner is the accent spinner. The other statuses never follow it.
  SemanticColors withAccent(Color accent, Brightness brightness) => copyWith(
    working: accent,
    workingSurface: accent.withValues(
      alpha: brightness == Brightness.dark ? _darkWorkingWash : _lightWash,
    ),
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
    Color? failureSurface,
    Color? workingSurface,
    Color? unread,
  }) {
    return SemanticColors(
      working: working ?? this.working,
      idle: idle ?? this.idle,
      attention: attention ?? this.attention,
      failure: failure ?? this.failure,
      diffAdded: diffAdded ?? this.diffAdded,
      diffRemoved: diffRemoved ?? this.diffRemoved,
      neutral: neutral ?? this.neutral,
      failureSurface: failureSurface ?? this.failureSurface,
      workingSurface: workingSurface ?? this.workingSurface,
      unread: unread ?? this.unread,
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
      failureSurface: Color.lerp(failureSurface, other.failureSurface, t)!,
      workingSurface: Color.lerp(workingSurface, other.workingSurface, t)!,
      unread: Color.lerp(unread, other.unread, t)!,
    );
  }
}

/// A colour a user gives a context so its header and chip are told apart at a
/// glance. Identity, never state: every hue keeps 20° from the hues
/// [SemanticColors] mean something by — no red, amber or green — so a
/// coloured context never reads as failing, waiting or done, and the hues
/// keep 24° from each other so they can be told apart. The accent is not
/// reserved — nor "working", which is the accent's spinner: a solid dot and
/// a turning ring are not confused. Stored by
/// [name]; the two variants each keep 3:1 against the band and the pane
/// surface of their theme (`context_hue_test`).
enum ContextHue {
  rose(Color(0xFFC43D6E), Color(0xFFF28BAF)),
  magenta(Color(0xFFA634A0), Color(0xFFE48EDE)),
  violet(Color(0xFF9842D6), Color(0xFFCC8EF7)),
  indigo(Color(0xFF5A4AD6), Color(0xFFAA9CF7)),
  slate(Color(0xFF566890), Color(0xFFA4B2CE)),
  teal(Color(0xFF1A8578), Color(0xFF5FD2C0)),
  olive(Color(0xFF6F7F1C), Color(0xFFC1CC5C));

  const ContextHue(this.light, this.dark);

  final Color light;
  final Color dark;

  Color of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The hue stored under [name], or null for anything else — an unknown name
  /// from a newer build is no colour, not a crash.
  static ContextHue? tryParse(String? name) {
    if (name == null) return null;
    for (final hue in values) {
      if (hue.name == name) return hue;
    }
    return null;
  }

  /// The word a picker shows for it.
  String get label => switch (this) {
    ContextHue.rose => 'Rose',
    ContextHue.magenta => 'Magenta',
    ContextHue.violet => 'Violet',
    ContextHue.indigo => 'Indigo',
    ContextHue.slate => 'Slate',
    ContextHue.teal => 'Teal',
    ContextHue.olive => 'Olive',
  };
}

/// Spacing scale (4-pt base). Use these instead of ad-hoc paddings.
class Insets {
  const Insets._();

  /// A hairline of ground around a badge's word — under the scale on purpose,
  /// so the badge does not grow the line it sits in.
  static const hair = 1.0;

  /// Between two lines of one item — a title and the line under it.
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// The washes an interactive surface is marked with. The one place an
/// accent or ink alpha is chosen; every hover, selection and drop reads here.
class StateLayers {
  const StateLayers._();

  static const hoverAlpha = 0.06;
  static const pressedAlpha = 0.10;
  static const selectedAlpha = 0.12;
  static const selectedFocusedAlpha = 0.18;
  static const dropTargetAlpha = 0.15;
  static const subtleAlpha = 0.08;
  static const textSelectionAlpha = 0.30;
  static const linkUnderlineAlpha = 0.40;
  static const focusRingAlpha = 0.6;

  /// A pointer over something interactive. Ink, not the accent.
  static Color hover(ColorScheme scheme) =>
      scheme.onSurface.withValues(alpha: hoverAlpha);

  static Color pressed(ColorScheme scheme) =>
      scheme.onSurface.withValues(alpha: pressedAlpha);

  /// A selected row, tab or destination.
  static Color selected(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: selectedAlpha);

  /// A selection that also holds keyboard focus.
  static Color selectedFocused(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: selectedFocusedAlpha);

  /// Where a drag will land.
  static Color dropTarget(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: dropTargetAlpha);

  /// A group or strip that owns focus, or will take a drop somewhere inside it.
  static Color subtle(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: subtleAlpha);

  static Color textSelection(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: textSelectionAlpha);

  static Color linkUnderline(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: linkUnderlineAlpha);

  /// Keyboard focus: a 1px inset ring rather than a second stacked fill, which
  /// vanished against a selected row on a light surface.
  static Color focusRing(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: focusRingAlpha);

  static const focusRingWidth = 1.0;
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

  /// Fully round ends: a status pill, a round send button.
  static const pill = 999.0;

  static const Radius card = Radius.circular(md);
}

/// Elevation drawn as a shadow, for surfaces that float over the workbench —
/// the palette, dialogs, toasts.
class Shadows {
  const Shadows._();

  static const floating = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.18),
      offset: Offset(0, 10),
      blurRadius: 24,
    ),
  ];
}

/// The elevation a Material surface is given, where it uses one.
class Elevations {
  const Elevations._();

  /// Popup menus and submenus.
  static const popup = 4.0;

  /// Dialogs.
  static const dialog = 12.0;
}

/// A dialog body's design width, for `BoundedDialogContent`. Three steps
/// rather than the nine hand-picked widths the dialogs had drifted to.
class DialogWidth {
  const DialogWidth._();

  /// A confirmation or a short form. Was 340, 380, 400 and 420.
  static const narrow = 420.0;

  /// An ordinary form or a list to pick from. Was 460, 480 and 520.
  static const regular = 520.0;

  /// A body with a table, a preview or two columns. Was 560 and 620.
  static const wide = 620.0;
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

  /// The glyph in an empty state — [Chrome.iconHero]'s touch counterpart, bigger
  /// because a phone's empty state owns the whole screen.
  static const iconHero = 32.0;

  /// A touch surface's app bar, at the default text scale.
  static const appBar = 56.0;

  /// [appBar] grown with the ambient text scale and never shrunk below the
  /// design height — a 200% title does not fit 56px, and the screen's own name
  /// is the worst thing to clip.
  static double appBarOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(appBar).clamp(appBar, 96.0);
}

/// How dense the *shared* cards and rows draw themselves. Read from a
/// [UiDensityScope], never the ambient width — a 300px pane is not a phone.
enum UiDensity {
  /// A mouse aims: dense rows, 11–13px glyphs, no target floor.
  pointer,

  /// A thumb does not: 48dp targets, roomier padding, one step up the ramp.
  touch;

  /// The Material compact breakpoint (CLAUDE.md §6). A **width** class and only
  /// that: measure is a width question, modality is not.
  static const compactWidth = 600.0;

  /// The density [platform] calls for: what its owner holds it with, because
  /// width stands in for modality and gets a tablet or a narrow window wrong.
  static UiDensity forPlatform(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.fuchsia ||
    TargetPlatform.iOS => UiDensity.touch,
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => UiDensity.pointer,
  };

  /// The density in effect for [context]; [UiDensity.pointer] with no scope.
  static UiDensity of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiDensityScope>()?.density ??
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

  /// For a control a pointer draws compact: compact density takes 8px off
  /// the 48dp tap target, so a thumb gets standard.
  VisualDensity get controlDensity =>
      isTouch ? VisualDensity.standard : VisualDensity.compact;

  /// For a control a pointer shrink-wraps: a thumb keeps the padded target.
  MaterialTapTargetSize get tapTargetSize =>
      isTouch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap;

  /// An icon button's constraints: [pointer] square under a pointer, the
  /// 48dp floor under a thumb.
  BoxConstraints iconConstraints(double pointer) => BoxConstraints(
    minWidth: isTouch ? Touch.target : pointer,
    minHeight: isTouch ? Touch.target : pointer,
  );

  /// A dense glyph's size: [pointer] under a pointer, [Touch.icon] under a
  /// thumb — never smaller than [pointer].
  double iconSize(double pointer) =>
      isTouch && pointer < Touch.icon ? Touch.icon : pointer;

  /// The strongest line on a card — a session's title, a project's name.
  TextStyle? title(ThemeData theme) =>
      (isTouch ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)
          ?.copyWith(fontWeight: FontWeight.w600);

  /// A list row's title: 13/18 w500 under a pointer, `titleMedium` under a
  /// thumb. [strong] is w600, kept for a row that is unread or needs you.
  TextStyle? rowTitle(ThemeData theme, {bool strong = false}) {
    final weight = strong ? FontWeight.w600 : FontWeight.w500;
    if (isTouch) {
      return theme.textTheme.titleMedium?.copyWith(fontWeight: weight);
    }
    return theme.textTheme.bodyMedium?.copyWith(
      fontSize: 13,
      height: 18 / 13,
      fontWeight: weight,
    );
  }

  /// The muted supporting lines: 11.5/16 w400 under a pointer. A phone steps
  /// up to `bodySmall` because that is under the floor for text a thumb's
  /// owner reads at arm's length.
  TextStyle? muted(ThemeData theme) {
    final color = theme.colorScheme.onSurfaceVariant;
    if (isTouch) {
      return theme.textTheme.bodySmall?.copyWith(
        color: color,
        letterSpacing: 0,
        fontWeight: FontWeight.w400,
      );
    }
    return theme.textTheme.labelSmall?.copyWith(
      color: color,
      fontSize: 11.5,
      height: 16 / 11.5,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    );
  }

  /// [base] re-tuned for this density: **identity** for [UiDensity.pointer].
  /// Sizes only — Material's compact density undoes the 48dp floor, so it goes.
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
          // The desktop theme pins button glyphs to `Chrome.icon`; a thumb
          // gets `Touch.icon`, the same step every other glyph takes here.
          iconSize: const WidgetStatePropertyAll(Touch.icon),
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
        indicatorColor: StateLayers.selected(scheme),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      dialogTheme: base.dialogTheme.copyWith(
        insetPadding: const EdgeInsets.all(Insets.xl),
      ),
      // The desktop theme pins these compact or shrink-wrapped, which undoes
      // the padded tap target set above.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: (base.segmentedButtonTheme.style ?? const ButtonStyle())
            .copyWith(
              visualDensity: VisualDensity.standard,
              minimumSize: const WidgetStatePropertyAll(Size(0, Touch.target)),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: (base.menuButtonTheme.style ?? const ButtonStyle()).copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(0, Touch.target)),
          textStyle: WidgetStatePropertyAll(text.bodyMedium),
          iconSize: const WidgetStatePropertyAll(Touch.icon),
        ),
      ),
      checkboxTheme: base.checkboxTheme.copyWith(
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
      radioTheme: base.radioTheme.copyWith(
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
      switchTheme: base.switchTheme.copyWith(
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }

  /// Installs the density for [child] and re-tunes the inherited theme. Read
  /// through `ThemeData.platform`, Flutter's own seam, so a test can name one.
  static Widget wrap(BuildContext context, Widget child) {
    final theme = Theme.of(context);
    final density = UiDensity.forPlatform(theme.platform);
    return UiDensityScope(
      density: density,
      child: Theme(data: density.themeFor(theme), child: child),
    );
  }
}

/// The width class of a region, per PROJECT.md §6: the one place a layout asks
/// "is this narrow?". Measured from the width the caller was *given* — its own
/// constraints — never the window's: a 300px pane in a 1440px window is compact.
enum WidthClass {
  /// Under [mediumMin]: one column, stacked rows.
  compact,

  /// [mediumMin] up to [expandedMin]. §6: default to the compact layout here
  /// unless the surface clearly gains from more.
  medium,

  /// [expandedMin] and up: side-by-side panes, rows with room for everything.
  expanded;

  /// Material's breakpoints, at 1x text. [mediumMin] is [UiDensity.compactWidth].
  static const mediumMin = UiDensity.compactWidth;
  static const expandedMin = 840.0;

  /// The body text size a scaler is read at. A non-linear scaler (Android 14)
  /// grows small text more than large, so the factor is taken where it matters.
  static const _referenceFontSize = 14.0;

  /// [breakpoint] grown with [textScaler]: at 2x text a row needs twice the
  /// width to hold the same words. Never shrunk — smaller text does not earn a
  /// layout more room than its design width.
  static double scaleBreakpoint(double breakpoint, TextScaler textScaler) {
    final factor = textScaler.scale(_referenceFontSize) / _referenceFontSize;
    return breakpoint * (factor < 1 ? 1 : factor);
  }

  /// The class of a region [width] logical pixels wide under [textScaler].
  static WidthClass of(
    double width, {
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (width < scaleBreakpoint(mediumMin, textScaler)) return compact;
    if (width < scaleBreakpoint(expandedMin, textScaler)) return medium;
    return expanded;
  }

  bool get isCompact => this == compact;
  bool get isExpanded => this == expanded;
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

/// Grows [child] to the 48dp [Touch.target] under a thumb, centred, and is
/// [child] itself under a pointer. Goes *inside* the `InkWell` or
/// `GestureDetector`, so the hit area grows while the glyph keeps its size.
class TouchTarget extends StatelessWidget {
  const TouchTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!UiDensity.of(context).isTouch) return child;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: Touch.target,
        minHeight: Touch.target,
      ),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    );
  }
}

/// Motion durations and curves. Animate through [Motion.of], which collapses
/// every duration to zero when the platform asks for reduced motion.
class Motion {
  const Motion._();

  /// Hover colour changes: none, so a pointer sweep never lags.
  static const instant = Duration.zero;

  /// Chevrons, focus borders.
  static const fast = Duration(milliseconds: 120);

  /// Expand and collapse, the composer's morph, a scroll to a row.
  static const base = Duration(milliseconds: 180);

  /// Sheets, dialogs, the context panel: in slower than out.
  static const emphasisIn = Duration(milliseconds: 300);
  static const emphasisOut = Duration(milliseconds: 200);

  static const standard = Cubic(0.4, 0, 0.2, 1);
  static const enter = Cubic(0.16, 1, 0.3, 1);
  static const exit = Cubic(0.7, 0, 0.84, 0);

  /// One turn of the working spinner, drawn in [statusSteps] discrete frames.
  static const statusPeriod = Duration(milliseconds: 1000);
  static const statusSteps = 12;

  static MotionDurations of(BuildContext context) =>
      MotionDurations(animate: !MediaQuery.disableAnimationsOf(context));
}

/// [Motion]'s durations as they apply under one context.
@immutable
class MotionDurations {
  const MotionDurations({required this.animate});

  /// False when the platform asks for reduced motion.
  final bool animate;

  Duration _or(Duration d) => animate ? d : Duration.zero;

  Duration get instant => Motion.instant;
  Duration get fast => _or(Motion.fast);
  Duration get base => _or(Motion.base);
  Duration get emphasisIn => _or(Motion.emphasisIn);
  Duration get emphasisOut => _or(Motion.emphasisOut);
  Duration get statusPeriod => _or(Motion.statusPeriod);
}

/// Fixed heights for the desktop chrome, in logical pixels, sized for a mouse.
/// Collected so the title bar, tab strip and pane chrome stay in proportion.
class Chrome {
  const Chrome._();

  /// The workbench tab strip, the context panel's header and every pane header.
  static const tabStrip = 30.0;

  /// The title bar at the top of the window — board A2's 38px row, which the
  /// owner chose over the 30px one it used to share with [tabStrip]. Its own
  /// value, not [tabStrip]'s: the bar now carries the quick panel field and
  /// the usage pills and wants the air around them, while the tab strip keeps
  /// its dense 30. Eight pixels apart the two read as distinct rows, where 32
  /// against 30 read as one slab.
  static const titleBar = 38.0;

  /// A **pane** header. Deliberately not [tabStrip]: drawn at the same height,
  /// the region header read as "an extra tab that doesn't do anything".
  static const paneStrip = 24.0;

  /// A one-line footer strip: the logs panel's footer, the context panel's
  /// context strip, quick open's hint row. Named for the global status bar it
  /// was first drawn for, which the UI overhaul removed (spec §2).
  static const statusBar = 22.0;

  /// A dense list row (explorer tree, palette results).
  static const row = 26.0;

  /// A menu row. [menuRow] is the house one-liner every popup draws; a picker
  /// whose choices need a sentence under the name gets [menuRowTall] instead,
  /// so the two kinds still read as one list.
  static const menuRow = 32.0;
  static const menuRowTall = 44.0;

  /// The widest a column of prose is allowed to get. Named because it was a bare
  /// `860` in three places, and three copies of a measure drift apart.
  static const readableWidth = 860.0;

  /// The chat view's column: **no cap** — the transcript and the composer
  /// take the pane's whole width (owner, 2026-09-28, over the spec's centred
  /// 780px column). A bubble still stops at [chatBubbleShare] of the row.
  static const chatWidth = double.infinity;

  /// The widest a user's message bubble grows, as a share of [chatWidth]:
  /// the rest is the gutter that says whose turn it is.
  static const chatBubbleShare = 0.85;

  /// One level of a file tree's indentation, narrower than [Insets.lg]: a 16px
  /// step runs a deep path off the side of the context panel.
  static const treeIndent = 14.0;

  /// How far a tree line with no row of its own clears the disclosure column, on
  /// top of its [treeIndent] — under its level's names, not under their carets.
  static const treeGutter = 22.0;

  /// The height of a control that has to sit inside a [titleBar] row — a menu
  /// button, the quick-open box, a window action. Short enough to leave a
  /// gutter above and below in a 30px row, tall enough to still be a target.
  static const control = 26.0;

  /// The diameter of a status dot. Read at a glance and never on its own:
  /// `StatusDot` requires a label, because a colour is not a state.
  static const dot = 7.0;

  /// Icon sizes: [icon] in toolbars, [iconSmall] inline with text,
  /// [iconTitle] in a dialog's title row, where it sits against `titleMedium`
  /// rather than body text and a toolbar glyph reads as an afterthought.
  static const icon = 16.0;
  static const iconSmall = 13.0;
  static const iconTitle = 18.0;

  /// The glyph on an action inside a dense row — dismiss, copy, trash, expand.
  /// Between [iconSmall] (a glyph set in a line of text) and [icon] (a glyph in
  /// a toolbar, where there is room), because a row's actions are neither.
  static const iconAction = 14.0;

  /// The glyph in an empty state: the one picture on a surface with nothing on
  /// it. Big enough to read as an illustration rather than as chrome, small
  /// enough to still fit the context panel at its 240px minimum.
  static const iconHero = 28.0;

  /// The label on a tab chip. Fixed rather than scaled, and named here for that
  /// reason: a chip sits in a [tabStrip] row that does not grow.
  static const TextStyle tabLabel = TextStyle(fontSize: 12);

  /// [tabLabel] a step down, for a [paneStrip] row. A pane is named *inside* a
  /// tab, so its name is set smaller than the tab's — the same hierarchy the
  /// two heights state, said again in type.
  static const TextStyle paneLabel = TextStyle(fontSize: 11);

  /// A group or section header — "PROJECTS", a settings section. Merged over
  /// `labelSmall` and written uppercase by the caller; nothing else is spaced.
  static const TextStyle groupLabel = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
  );

  /// [titleBar] grown with the ambient text scale, and never shrunk below the
  /// design height: a 150% menu label does not fit a 38px row, and clipping
  /// the menu bar was exactly the "menus ignore text sizing" bug.
  static double titleBarOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(titleBar).clamp(titleBar, 52.0);

  /// [tabStrip], same treatment, for a row whose label follows the text scale —
  /// a pane header's eyebrow does; a tab chip's [tabLabel] deliberately does not.
  static double tabStripOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(tabStrip).clamp(tabStrip, 52.0);

  /// The one-column window's top bar (UI overhaul board N4, Compact): taller
  /// than [titleBar] because it carries the session switcher and two 34px
  /// buttons — the controls a window that narrow is driven by.
  static const compactTopBar = 44.0;

  /// A workbench page tab's title bar — Stores, Usage, Logs: a glyph, the
  /// page's name in the app bar's title style, its controls and actions.
  static const tabAppBar = 44.0;

  /// [tabAppBar] grown with the text scale; under a thumb, never under
  /// [Touch.appBarOf], so its actions keep their 48dp targets.
  static double tabAppBarOf(BuildContext context) {
    final scaled = MediaQuery.textScalerOf(
      context,
    ).scale(tabAppBar).clamp(tabAppBar, 64.0);
    if (!UiDensity.of(context).isTouch) return scaled;
    final touch = Touch.appBarOf(context);
    return scaled > touch ? scaled : touch;
  }

  /// [compactTopBar], grown with the text scale as [titleBarOf] is.
  static double compactTopBarOf(BuildContext context) =>
      MediaQuery.textScalerOf(
        context,
      ).scale(compactTopBar).clamp(compactTopBar, 60.0);

  /// [statusBar], same treatment.
  static double statusBarOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(statusBar).clamp(statusBar, 38.0);
}

/// The monospace family for the "ledger hand" — paths, ids, event types,
/// diffs — on [platform]. A named face per OS, because a bare `monospace`
/// resolves unpredictably off Linux; always paired with [monoFallbackFor].
String monoFamilyFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.iOS => 'Menlo',
  TargetPlatform.windows => 'Cascadia Mono',
  TargetPlatform.linux => 'DejaVu Sans Mono',
  TargetPlatform.android || TargetPlatform.fuchsia => 'monospace',
};

/// What [monoFamilyFor] falls back to, ending in the generic `monospace`.
List<String> monoFallbackFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.iOS => const ['Monaco', 'monospace'],
  TargetPlatform.windows => const ['Consolas', 'monospace'],
  TargetPlatform.linux => const ['Liberation Mono', 'monospace'],
  TargetPlatform.android || TargetPlatform.fuchsia => const ['monospace'],
};

/// The bundled ledger hand, JetBrains Mono (SIL OFL), declared in this
/// package's pubspec: every machine draws the same figures. A package font is
/// named with its package prefix.
const String kBundledMonoFamily = 'packages/karmashala_ui/JetBrainsMono';

/// Bundled symbol faces (Noto, SIL OFL) for a terminal's marks — ⏵ ⏸ ⏺ ⎿ ✻ ✽
/// ◐ — which JetBrains Mono lacks; Android has no glyph for ⏵ or ⎿ at all.
const List<String> kBundledSymbolFamilies = [
  'packages/karmashala_ui/NotoSansSymbols2',
  'packages/karmashala_ui/NotoSansSymbols',
];

/// The bundled UI face, Geist (SIL OFL).
const String kBundledSansFamily = 'packages/karmashala_ui/Geist';

/// The ledger hand. Set it with [kMonoFallback] beside it: the platform's own
/// face follows the bundled one, for a glyph JetBrains Mono does not carry.
String get kMonoFamily => kBundledMonoFamily;
List<String> get kMonoFallback => [
  monoFamilyFor(defaultTargetPlatform),
  ...monoFallbackFor(defaultTargetPlatform),
];

/// The UI sans on Linux, where the system default varies by distribution.
/// Elsewhere the platform's own UI font follows Geist as it is.
List<String>? uiSansFallbackFor(TargetPlatform platform) =>
    platform == TargetPlatform.linux
    ? const ['Inter', 'Cantarell', 'Noto Sans']
    : null;

/// The ledger hand's text styles, in the theme layer where a size may be
/// named. Feature widgets use these instead of their own `fontSize:`.
class MonoStyles {
  const MonoStyles._();

  static TextStyle _mono(double size) => TextStyle(
    fontFamily: kMonoFamily,
    fontFamilyFallback: kMonoFallback,
    fontSize: size,
  );

  /// Inline identifiers beside label-sized text (chips, badges).
  static TextStyle get small => _mono(11);

  /// The default ledger hand: paths, ids, environment names.
  static TextStyle get body => _mono(12);

  /// A ledger value promoted to sit beside body text (a hotkey combo).
  static TextStyle get label => _mono(13);
}

/// **The chrome's type sizes**, named where a size may be named, for the
/// compact surfaces whose text is set tighter than the Material `TextTheme`
/// — the sidebar, the settings pages, Quick Open and the toolbar cards. A
/// widget merges one of these over a theme style rather than writing its
/// own number; the steps are the mockup's.
class TypeSizes {
  const TypeSizes._();

  /// A settings nav section's small capitals.
  static const double micro = 10.5;

  /// A group label or a key hint: [Chrome.paneLabel]'s size.
  static const double caption = 11;

  /// A tab, a filter, a card's secondary line: [Chrome.tabLabel]'s size.
  static const double label = 12;

  /// A quiet field and a nav row.
  static const double field = 12.5;

  /// A card's body and an area header's title.
  static const double body = 13;

  /// A palette's input.
  static const double input = 14;

  /// A settings page title, narrow and wide.
  static const double title = 16;
  static const double titleLarge = 19;
}

/// How long a pause in typing is waited for before work that follows typing
/// runs again. A latency, not motion, so reduced motion does not shorten it.
class Latency {
  const Latency._();

  /// A search over a buffer, re-run as its query or its text changes.
  static const searchDebounce = Duration(milliseconds: 150);

  /// How long letters typed into a list are one word: `c`, `h` within it goes
  /// to "charlie", after it `h` starts a new search. What file managers use.
  static const typeAhead = Duration(milliseconds: 700);
}

/// The sixteen ANSI colours a log or a command's output names, in the order
/// SGR numbers them (black … white, then the bright eight), per brightness.
abstract final class AnsiPalette {
  static List<Color> of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static const _dark = <Color>[
    Color(0xFF15161E),
    Color(0xFFF7768E),
    Color(0xFF9ECE6A),
    Color(0xFFE0AF68),
    Color(0xFF7AA2F7),
    Color(0xFFBB9AF7),
    Color(0xFF7DCFFF),
    Color(0xFFA9B1D6),
    Color(0xFF414868),
    Color(0xFFFF899D),
    Color(0xFFB9F27C),
    Color(0xFFFFC777),
    Color(0xFF8DB0FF),
    Color(0xFFC7A9FF),
    Color(0xFFA4DAFF),
    Color(0xFFC0CAF5),
  ];

  static const _light = <Color>[
    Color(0xFF3B3F51),
    Color(0xFFD20F39),
    Color(0xFF40831E),
    Color(0xFF8C6C3E),
    Color(0xFF2E7DE9),
    Color(0xFF9854F1),
    Color(0xFF007197),
    Color(0xFF6172B0),
    Color(0xFF6C6F85),
    Color(0xFFF52A65),
    Color(0xFF587539),
    Color(0xFFB15C00),
    Color(0xFF3760BF),
    Color(0xFF7847BD),
    Color(0xFF0F7B8A),
    Color(0xFF3760BF),
  ];
}
