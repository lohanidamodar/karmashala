import 'package:flutter/material.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// A `MaterialApp` for a screen shown outside the main app (pairing, the
/// grant page, a failed open), with the same touch density and theme as
/// `KarmashalaApp`, so a phone's buttons there are 48dp too.
class BareApp extends StatelessWidget {
  const BareApp({super.key, required this.density, required this.home});

  final UiDensity density;
  final Widget home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Karmashala',
    debugShowCheckedModeBanner: false,
    builder: (context, child) =>
        UiDensityScope(density: density, child: child!),
    // Identity for pointer, so the desktop's screens are as before.
    theme: density.themeFor(AppTheme.light()),
    darkTheme: density.themeFor(AppTheme.dark()),
    home: home,
  );
}
