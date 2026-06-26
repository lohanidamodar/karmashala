import 'package:flutter/material.dart';

/// Application theming.
///
/// A single seed colour drives Material 3 light and dark schemes so the desktop
/// shell has a consistent, intentional look without per-widget colour juggling.
class AppTheme {
  const AppTheme._();

  static const Color _seed = Color(0xFF3D5AFE);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: colorScheme.surface,
    );
  }
}
