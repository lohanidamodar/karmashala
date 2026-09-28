import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'appearance.dart';
import 'design_tokens.dart';

/// A neutral desktop chrome with one accent. Written out rather than seeded:
/// `fromSeed` tints every surface, which a neutral ramp must not do.
///
/// The Material roles sit on the tone ladder of the UI overhaul (spec §3):
/// `surface` is the window, `surfaceContainerLowest` the terminal, then the
/// sidebar, chrome, raised, selected steps. [SurfaceTones] names the same
/// steps for the shell's regions.
class AppTheme {
  const AppTheme._();

  static ThemeData light({
    AppearanceOptions options = const AppearanceOptions(),
  }) => _build(Brightness.light, options);

  static ThemeData dark({
    AppearanceOptions options = const AppearanceOptions(),
  }) => _build(Brightness.dark, options);

  static ColorScheme _scheme(Brightness brightness, AppearanceOptions options) {
    final accent = options.accent.forBrightness(brightness);
    final borders = options.separation == SurfaceSeparation.borders;
    if (brightness == Brightness.light) {
      return ColorScheme(
        brightness: Brightness.light,
        primary: accent,
        onPrimary: Colors.white,
        primaryContainer: Color.alphaBlend(
          accent.withValues(alpha: 0.14),
          const Color(0xFFFBFBFA),
        ),
        onPrimaryContainer: const Color(0xFF10203F),
        secondary: const Color(0xFF6B6B73),
        onSecondary: Colors.white,
        secondaryContainer: const Color(0xFFE9E9E6),
        onSecondaryContainer: const Color(0xFF1D1D20),
        tertiary: accent,
        onTertiary: Colors.white,
        tertiaryContainer: Color.alphaBlend(
          accent.withValues(alpha: 0.14),
          const Color(0xFFFBFBFA),
        ),
        onTertiaryContainer: const Color(0xFF10203F),
        error: AppColors.dangerLight,
        onError: Colors.white,
        errorContainer: const Color(0xFFF9DEDC),
        onErrorContainer: const Color(0xFF410E0B),
        surface: const Color(0xFFFBFBFA),
        onSurface: const Color(0xFF1D1D20),
        onSurfaceVariant: const Color(0xFF6B6B73),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFF5F5F3),
        surfaceContainer: const Color(0xFFEEEEEB),
        surfaceContainerHigh: const Color(0xFFE9E9E6),
        surfaceContainerHighest: const Color(0xFFDCDCD8),
        surfaceTint: accent,
        outline: const Color(0xFF9A9AA2),
        outlineVariant: borders
            ? const Color(0xFFDCDCD8)
            : const Color(0xFFE9E9E6),
        inverseSurface: const Color(0xFF2B2B31),
        onInverseSurface: const Color(0xFFF2F2F4),
        inversePrimary: options.accent.onDark,
        shadow: Colors.black,
        scrim: Colors.black,
      );
    }
    return ColorScheme(
      brightness: Brightness.dark,
      primary: accent,
      onPrimary: const Color(0xFF0E0E10),
      primaryContainer: Color.alphaBlend(
        accent.withValues(alpha: 0.22),
        const Color(0xFF0E0E10),
      ),
      onPrimaryContainer: const Color(0xFFE3EAFF),
      secondary: const Color(0xFF8A8A93),
      onSecondary: const Color(0xFF0E0E10),
      secondaryContainer: const Color(0xFF1F1F24),
      onSecondaryContainer: const Color(0xFFE7E7EA),
      tertiary: accent,
      onTertiary: const Color(0xFF0E0E10),
      tertiaryContainer: Color.alphaBlend(
        accent.withValues(alpha: 0.22),
        const Color(0xFF0E0E10),
      ),
      onTertiaryContainer: const Color(0xFFE3EAFF),
      error: AppColors.dangerDark,
      onError: const Color(0xFF3B0906),
      errorContainer: const Color(0xFF62211C),
      onErrorContainer: const Color(0xFFFFDAD6),
      surface: const Color(0xFF0E0E10),
      onSurface: const Color(0xFFE7E7EA),
      onSurfaceVariant: const Color(0xFF8A8A93),
      surfaceContainerLowest: const Color(0xFF0C0C0E),
      surfaceContainerLow: const Color(0xFF121215),
      surfaceContainer: const Color(0xFF141417),
      surfaceContainerHigh: const Color(0xFF17171B),
      surfaceContainerHighest: const Color(0xFF1F1F24),
      surfaceTint: accent,
      outline: const Color(0xFF5F5F68),
      outlineVariant: borders
          ? const Color(0xFF26262C)
          : const Color(0xFF1A1A1F),
      inverseSurface: const Color(0xFFE7E7EA),
      onInverseSurface: const Color(0xFF1D1D20),
      inversePrimary: options.accent.onLight,
      shadow: Colors.black,
      scrim: Colors.black,
    );
  }

  static ThemeData _build(Brightness brightness, AppearanceOptions options) {
    final scheme = _scheme(brightness, options);
    final sansFallback = uiSansFallbackFor(defaultTargetPlatform);
    final text = _textTheme(
      scheme,
    ).apply(fontFamily: kBundledSansFamily, fontFamilyFallback: sansFallback);
    final tones = SurfaceTones.forBrightness(
      brightness,
      separation: options.separation,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      fontFamily: kBundledSansFamily,
      fontFamilyFallback: sansFallback,
      extensions: [
        SemanticColors.forBrightness(brightness),
        tones,
      ],
      // A neutral chrome has no business tinting elevated surfaces towards the
      // accent; the ramp already says how high a surface is.
      applyElevationOverlayColor: false,
      splashFactory: InkSparkle.splashFactory,
      hoverColor: StateLayers.hover(scheme),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleSmall,
        toolbarHeight: Chrome.titleBar,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(26),
          maximumSize: const Size.square(30),
          padding: const EdgeInsets.all(Insets.xs),
          // An `IconButton` sizes its glyph from its own button style, not from the
          // ambient `iconTheme` — unset, every one fell back to Material's 24.
          iconSize: Chrome.icon,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
        ),
      ),
      iconTheme: IconThemeData(
        size: Chrome.icon,
        color: scheme.onSurfaceVariant,
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.primary,
        selectedTileColor: StateLayers.selected(scheme),
        iconColor: scheme.onSurfaceVariant,
        // Material's default title is `bodyLarge`, larger than the `bodyMedium` a
        // dialog's own content is set in, so a tile shouted over its explanation.
        titleTextStyle: text.bodyMedium,
        subtitleTextStyle: text.bodySmall,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: 0,
        ),
        minVerticalPadding: 2,
        minLeadingWidth: 20,
        horizontalTitleGap: Insets.sm,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: _inputBorder(scheme.outlineVariant),
        enabledBorder: _inputBorder(scheme.outlineVariant),
        focusedBorder: _inputBorder(scheme.primary, width: 1.5),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.sm,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
        ),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerLow,
        labelStyle: text.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      ),
      // `*.icon` constructors size their leading glyph from the button style too,
      // and Material's default is 18 against a chrome of `Chrome.icon`.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
          iconSize: Chrome.icon,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 30),
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
          iconSize: Chrome.icon,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
          iconSize: Chrome.icon,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
          ),
        ),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
      // A floating note on the raised tone with the floating hairline, like
      // every other card that hovers over the window - not Material's light
      // inverse bar across the whole width.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: tones.raised,
        contentTextStyle: text.bodySmall?.copyWith(color: scheme.onSurface),
        actionTextColor: scheme.primary,
        width: 480,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: tones.floatingLine),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        textStyle: text.labelSmall?.copyWith(
          color: scheme.onInverseSurface,
          letterSpacing: 0,
        ),
        waitDuration: const Duration(milliseconds: 450),
      ),
      popupMenuTheme: PopupMenuThemeData(
        position: PopupMenuPosition.under,
        elevation: Elevations.popup,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        textStyle: text.bodySmall,
        // Under Material 3 a `PopupMenuItem` reads `labelTextStyle` and ignores
        // `textStyle`. Both are set, to one style, because either may be the one read.
        labelTextStyle: WidgetStatePropertyAll(text.bodySmall),
        iconColor: scheme.onSurfaceVariant,
        iconSize: Chrome.icon,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: Elevations.dialog,
        alignment: Alignment.center,
        insetPadding: const EdgeInsets.all(32),
        titleTextStyle: text.titleMedium,
        contentTextStyle: text.bodyMedium,
        actionsPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      // The panel a `SubmenuButton` opens. Deliberately the same values as
      // `popupMenuTheme`: two menus meant to look identical read from one set.
      menuTheme: MenuThemeData(
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(Elevations.popup),
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.sm),
              side: BorderSide(color: scheme.outlineVariant),
            ),
          ),
        ),
      ),
      menuBarTheme: MenuBarThemeData(
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          minimumSize: const WidgetStatePropertyAll(Size(0, 26)),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 26)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: Insets.sm),
          ),
          textStyle: WidgetStatePropertyAll(text.bodySmall),
          // A `MenuItemButton`'s leading icon is sized by the button style, not the
          // ambient `iconTheme`, so these came out at Material's 24pt default.
          iconSize: const WidgetStatePropertyAll(Chrome.icon),
          iconColor: WidgetStatePropertyAll(scheme.onSurfaceVariant),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.sm),
              side: BorderSide(color: scheme.outlineVariant),
            ),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
      switchTheme: const SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: 0.35),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
        borderSide: BorderSide(color: color, width: width),
      );

  /// Intentional type scale: tighter, confident titles; calm body; a small
  /// label that is body text too, so its spacing stays near zero. Group
  /// headers take [Chrome.groupLabel] on top of it.
  static TextTheme _textTheme(ColorScheme scheme) {
    final typography = Typography.material2021(colorScheme: scheme);
    // Light-on-dark glyph colours in dark mode; always using the `.black` set is
    // what made dark text unreadable.
    final colours = scheme.brightness == Brightness.dark
        ? typography.white
        : typography.black;
    // The geometry has to be merged in here: `typography.black`/`.white` carry no
    // font sizes, so a captured component style inherits whatever is ambient.
    final base = typography.englishLike.merge(colours);
    final onSurface = scheme.onSurface;
    return base.copyWith(
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: onSurface,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: onSurface,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      labelSmall: base.labelSmall?.copyWith(
        letterSpacing: 0.1,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
      bodyMedium: base.bodyMedium?.copyWith(color: onSurface, height: 1.45),
      bodySmall: base.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
  }
}
