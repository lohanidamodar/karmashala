import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Application theming — a neutral desktop chrome with one accent.
///
/// The scheme is written out rather than seeded: `ColorScheme.fromSeed` tints
/// every surface towards the seed hue, which is exactly what a neutral ramp must
/// not do. Greys are grey; the accent appears only on selection, focus and the
/// primary action; anything that carries meaning comes from [SemanticColors].
///
/// `primary` and `tertiary` are deliberately the same colour. Material hands
/// widgets three "brand" slots, and the direction allows one accent — aliasing
/// them means a widget cannot accidentally introduce a second brand colour by
/// reaching for the other slot.
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
    final text = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      fontFamily: null,
      extensions: [SemanticColors.forBrightness(brightness)],
      // A neutral chrome has no business tinting elevated surfaces towards the
      // accent; the ramp already says how high a surface is.
      applyElevationOverlayColor: false,
      splashFactory: InkSparkle.splashFactory,
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
        selectedTileColor: scheme.primary.withValues(alpha: 0.10),
        iconColor: scheme.onSurfaceVariant,
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
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
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
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
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
        elevation: 8,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        textStyle: text.bodySmall,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
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
      // The panel a `SubmenuButton` opens. Without this it fell back to
      // Material's defaults while every other menu in the app came from
      // `popupMenuTheme` — a different surface, a heavier elevation, no
      // border and different padding, all in a menu sitting inches from the
      // ones it disagreed with. Deliberately the same values as
      // `popupMenuTheme` above rather than similar ones: two menus that are
      // meant to look identical should read from one set of numbers.
      menuTheme: MenuThemeData(
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(8),
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
          // A `MenuItemButton`'s leading icon is sized by the button style,
          // not by the ambient `iconTheme`, so these came out at Material's
          // 24pt default beside body-small labels while the same icon in a
          // toolbar or a popup menu was `Chrome.icon`.
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

  /// Intentional type scale: tighter, confident titles; calm body; a spaced,
  /// small label used as the chrome eyebrow.
  static TextTheme _textTheme(ColorScheme scheme) {
    final typography = Typography.material2021(colorScheme: scheme);
    // Use light-on-dark glyph colours in dark mode (the bug that made dark text
    // unreadable was always using the `.black` set).
    final base = scheme.brightness == Brightness.dark
        ? typography.white
        : typography.black;
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
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
      bodyMedium: base.bodyMedium?.copyWith(color: onSurface, height: 1.35),
      bodySmall: base.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
  }
}
