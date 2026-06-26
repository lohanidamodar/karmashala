import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Application theming — the "ink & brass on parchment" identity (see
/// [AppColors]). One seed (indigo ink) drives the Material 3 scheme; brass is
/// injected as the accent (tertiary) and surfaces are warmed so the app reads
/// like a record-keeper's ledger rather than a default blue Material app.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final base = ColorScheme.fromSeed(
      seedColor: AppColors.ink,
      brightness: brightness,
    );

    final scheme = isLight
        ? base.copyWith(
            primary: AppColors.ink,
            tertiary: AppColors.brass,
            onTertiary: Colors.white,
            surface: AppColors.parchment,
            surfaceContainerLowest: Colors.white,
            surfaceContainerLow: const Color(0xFFF7F3EA),
            surfaceContainer: AppColors.parchmentDim,
            surfaceContainerHigh: const Color(0xFFEDE7DA),
            surfaceContainerHighest: const Color(0xFFE7E0D1),
            outlineVariant: const Color(0xFFD9D2C4),
            error: AppColors.danger,
          )
        : base.copyWith(
            primary: AppColors.inkBright,
            tertiary: AppColors.brassBright,
            onTertiary: Colors.black,
            surface: AppColors.slate,
            surfaceContainerLowest: const Color(0xFF100E18),
            surfaceContainerLow: const Color(0xFF1A1726),
            surfaceContainer: AppColors.slateRaised,
            surfaceContainerHigh: const Color(0xFF262238),
            surfaceContainerHighest: const Color(0xFF2E2942),
            outlineVariant: const Color(0xFF332E45),
          );

    final text = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      fontFamily: null,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleMedium,
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primary.withValues(alpha: 0.08),
        iconColor: scheme.onSurfaceVariant,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: 0,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: _inputBorder(scheme.outlineVariant),
        enabledBorder: _inputBorder(scheme.outlineVariant),
        focusedBorder: _inputBorder(scheme.primary, width: 1.5),
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
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
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
        iconColor: scheme.primary,
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
        textStyle: text.labelSmall?.copyWith(color: scheme.onInverseSurface),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
        borderSide: BorderSide(color: color, width: width),
      );

  /// Intentional type scale: tighter, confident titles; calm body; a spaced,
  /// small label used as the "ledger" eyebrow.
  static TextTheme _textTheme(ColorScheme scheme) {
    final base = Typography.material2021(colorScheme: scheme).black;
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
