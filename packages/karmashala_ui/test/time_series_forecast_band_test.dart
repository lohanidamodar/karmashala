import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/charts.dart';

import 'support/layout_probe.dart';

/// The time series' forecast band (round 84): a faint fill between the slower
/// and faster projections, painted only when given, beside the dashed line
/// and a reset marker.
void main() {
  final start = DateTime.utc(2026, 10, 9, 8);
  final end = start.add(const Duration(hours: 6));
  final now = start.add(const Duration(hours: 3));
  final reset = start.add(const Duration(hours: 5));

  TimeSeriesGeometry geometry() => TimeSeriesGeometry(
    size: const Size(300, 120),
    start: start,
    end: end,
    minY: 0,
    maxY: 100,
    axisStyle: const TextStyle(fontSize: 11),
    scaler: TextScaler.noScaling,
    valueLabel: (v) => '$v',
    timeLabel: (t) => '$t',
  );

  final band = [
    TimeSeriesBandPoint(now, 40, 40),
    TimeSeriesBandPoint(reset, 70, 100),
  ];

  _Canvas paint({List<TimeSeriesBandPoint> forecastBand = const []}) {
    final canvas = _Canvas();
    TimeSeriesPainter(
      geometry: geometry(),
      points: [TimeSeriesPoint(start, 10), TimeSeriesPoint(now, 40)],
      color: Colors.teal,
      ink: _ink,
      markers: [ChartMarker(reset, label: 'resets')],
      forecast: [TimeSeriesPoint(now, 40), TimeSeriesPoint(reset, 85)],
      forecastBand: forecastBand,
    ).paint(canvas, const Size(300, 120));
    return canvas;
  }

  test('a band is filled at the band alpha, between its edges', () {
    final fills = paint(forecastBand: band).fillAlphas;
    expect(fills, contains(closeTo(ChartAlphas.band, 0.01)));
  });

  test('no band is painted when none is given', () {
    final fills = paint().fillAlphas;
    expect(fills, isNot(contains(closeTo(ChartAlphas.band, 0.01))));
  });

  test('the reset marker is drawn as a vertical rule at its moment', () {
    final x = geometry().xFor(reset);
    final lines = paint(forecastBand: band).lines;
    expect(
      lines.where((l) => (l.$1.dx - x).abs() < 0.01 && l.$1.dx == l.$2.dx),
      isNotEmpty,
    );
  });

  testWidgets('a chart with a band and a marker lays out from 360px at 1.6', (
    tester,
  ) async {
    for (final width in [360.0, 412.0, 900.0]) {
      final overflows = await pumpInBox(
        tester,
        width: width,
        textScale: 1.6,
        child: TimeSeriesChart(
          points: [TimeSeriesPoint(start, 10), TimeSeriesPoint(now, 40)],
          forecast: [TimeSeriesPoint(now, 40), TimeSeriesPoint(reset, 85)],
          forecastBand: band,
          markers: [ChartMarker(reset, label: 'resets')],
          start: start,
          end: end,
          color: Colors.teal,
          semanticsLabel: 'with a band',
          valueLabel: (v) => '${v.round()}%',
          timeLabel: (t) => '${t.hour}:00',
        ),
      );
      expect(overflows, isEmpty, reason: '$width');
      expect(tester.takeException(), isNull);
    }
  });
}

/// Records the fills and the lines a painter draws.
class _Canvas extends Fake implements Canvas {
  final fillAlphas = <double>[];
  final lines = <(Offset, Offset)>[];

  @override
  void drawPath(Path path, Paint paint) {
    if (paint.style == PaintingStyle.fill) fillAlphas.add(paint.color.a);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2));

  @override
  void drawCircle(Offset c, double radius, Paint paint) {}

  @override
  void save() {}

  @override
  void restore() {}

  @override
  void clipRect(
    Rect rect, {
    ClipOp clipOp = ClipOp.intersect,
    bool doAntiAlias = true,
  }) {}

  @override
  void drawParagraph(dynamic paragraph, Offset offset) {}
}

const _ink = ChartInk(
  grid: Colors.grey,
  axisLabel: TextStyle(fontSize: 11),
  track: Colors.grey,
  marker: Colors.black54,
  tooltipBackground: Colors.white,
  tooltipBorder: Colors.grey,
  tooltipText: TextStyle(),
  brightness: Brightness.light,
);
