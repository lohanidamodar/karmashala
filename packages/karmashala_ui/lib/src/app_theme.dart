import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// A neutral desktop chrome with one accent. Written out rather than seeded:
/// `fromSeed` tints every surface, which a neutral ramp must not do.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ColorScheme _scheme(Brightness brightness) {
    if (brightness == Brightness.light) {
      const accent = AppColors.accentLight;
      return const ColorScheme(
        brightness: Brightness.light,
        primary: accent,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFDCE6FB),
        onPrimaryContainer: Color(0xFF10305F),
        secondary: AppColors.lightOnVariant,
        onSecondary: Colors.white,
        secondaryContainer: AppColors.lightHigh,
        onSecondaryContainer: AppColors.lightOn,
        tertiary: accent,
        onTertiary: Colors.white,
        tertiaryContainer: Color(0xFFDCE6FB),
        onTertiaryContainer: Color(0xFF10305F),
        error: AppColors.dangerLight,
        onError: Colors.white,
        errorContainer: Color(0xFFF9DEDC),
        onErrorContainer: Color(0xFF410E0B),
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightOn,
        onSurfaceVariant: AppColors.lightOnVariant,
        surfaceContainerLowest: AppColors.lightLowest,
        surfaceContainerLow: AppColors.lightLow,
        surfaceContainer: AppColors.lightContainer,
        surfaceContainerHigh: AppColors.lightHigh,
        surfaceContainerHighest: AppColors.lightHighest,
        surfaceTint: accent,
        outline: AppColors.lightOutline,
        outlineVariant: AppColors.lightOutlineVariant,
        inverseSurface: Color(0xFF2B2B31),
        onInverseSurface: Color(0xFFF2F2F4),
        inversePrimary: AppColors.accentDark,
        shadow: Colors.black,
        scrim: Colors.black,
      );
    }
    const accent = AppColors.accentDark;
    return const ColorScheme(
      brightness: Brightness.dark,
      primary: accent,
      onPrimary: Color(0xFF0B1B36),
      primaryContainer: Color(0xFF22365C),
      onPrimaryContainer: Color(0xFFD7E3FF),
      secondary: AppColors.darkOnVariant,
      onSecondary: Color(0xFF14141A),
      secondaryContainer: AppColors.darkHigh,
      onSecondaryContainer: AppColors.darkOn,
      tertiary: accent,
      onTertiary: Color(0xFF0B1B36),
      tertiaryContainer: Color(0xFF22365C),
      onTertiaryContainer: Color(0xFFD7E3FF),
      error: AppColors.dangerDark,
      onError: Color(0xFF3B0906),
      errorContainer: Color(0xFF62211C),
      onErrorContainer: Color(0xFFFFDAD6),
      surface: AppColors.darkSurface,
      onSurface: AppColors.darkOn,
      onSurfaceVariant: AppColors.darkOnVariant,
      surfaceContainerLowest: AppColors.darkLowest,
      surfaceContainerLow: AppColors.darkLow,
      surfaceContainer: AppColors.darkContainer,
      surfaceContainerHigh: AppColors.darkHigh,
      surfaceContainerHighest: AppColors.darkHighest,
      surfaceTint: accent,
      outline: AppColors.darkOutline,
      outlineVariant: AppColors.darkOutlineVariant,
      inverseSurface: Color(0xFFE4E4E9),
      onInverseSurface: Color(0xFF1B1B1F),
      inversePrimary: AppColors.accentLight,
      shadow: Colors.black,
      scrim: Colors.black,
    );
  }

  static ThemeData _build(Brightness brightness) {
    final scheme = _scheme(brightness);
    final sansFallback = uiSansFallbackFor(defaultTargetPlatform);
    final text = sansFallback == null
        ? _textTheme(scheme)
        : _textTheme(scheme).apply(fontFamilyFallback: sansFallback);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      fontFamily: null,
      fontFamilyFallback: sansFallback,
      extensions: [SemanticColors.forBrightness(brightness)],
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
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
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
