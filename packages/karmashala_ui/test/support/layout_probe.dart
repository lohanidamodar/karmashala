import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// The text scales every layout sweep in this package is asserted at: the
/// default, the settings screen's step above it, and the OS maximum.
const sweepScales = [1.0, 1.3, 2.0];

/// Pumps [child] into a [width] x [height] box under [density] and [textScale],
/// and returns every overflow reported while it laid out.
///
/// Uses the test font on purpose: its glyphs are twice a real font's width, so
/// a layout that passes here passes with any shipped font.
Future<List<String>> pumpInBox(
  WidgetTester tester, {
  required Widget child,
  required double width,
  double? height,
  double textScale = 1.0,
  UiDensity density = UiDensity.pointer,
  ThemeData? theme,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1200);
  addTearDown(tester.view.reset);

  final base = theme ?? AppTheme.light();
  final overflows = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = '${details.exception}';
    if (message.contains('overflowed by')) {
      overflows.add(message.split('\n').first);
    } else {
      previous?.call(details);
    }
  };
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: density.themeFor(base),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: UiDensityScope(
              density: density,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: width, height: height, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  } finally {
    FlutterError.onError = previous;
  }
  return overflows;
}
