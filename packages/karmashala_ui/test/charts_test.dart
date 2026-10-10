import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/src/charts/chart_support.dart';
import 'package:karmashala_ui/theme.dart';

import 'support/layout_probe.dart';

/// The hand-painted charts. What a caller relies on: painting never throws on
/// the data it can actually hand over (nothing, one reading, a lot), at any
/// size a layout can produce; a chart names itself to a screen reader; axes go
/// when there is no room for them; hover and tap explain a mark; and reduced
/// motion means no tween.
void main() {
  final start = DateTime.utc(2026, 9, 16, 8);
  final end = start.add(const Duration(hours: 5));

  List<TimeSeriesPoint> series(int count) => [
    for (var i = 0; i < count; i++)
      TimeSeriesPoint(
        start.add(Duration(minutes: count == 1 ? 60 : 300 * i ~/ (count - 1))),
        (i * 7 % 100).toDouble(),
      ),
  ];

  List<BarDatum> bars(int count) => [
    for (var i = 0; i < count; i++)
      BarDatum(label: 'Day ${i + 1}', value: (i * 13 % 40).toDouble()),
  ];

  const sizes = [
    Size.zero,
    Size(1, 1),
    Size(12, 4),
    Size(80, 20),
    Size(640, 200),
  ];
  const counts = [0, 1, 2, 60];

  ChartInk ink() => const ChartInk(
    grid: Color(0xFFCCCCCC),
    axisLabel: TextStyle(fontSize: 11, color: Color(0xFF555555)),
    track: Color(0xFFEEEEEE),
    marker: Color(0xFF777777),
    tooltipBackground: Color(0xFFFFFFFF),
    tooltipBorder: Color(0xFFDDDDDD),
    tooltipText: TextStyle(fontSize: 12),
    brightness: Brightness.light,
  );

  void paintAt(CustomPainter painter, Size size) {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), size);
    recorder.endRecording().dispose();
  }

  group('painting never throws', () {
    for (final size in sizes) {
      for (final count in counts) {
        test('at ${size.width}x${size.height} with $count readings', () {
          final values = [for (var i = 0; i < count; i++) i * 3.0];
          paintAt(
            SparklinePainter(
              values: values,
              color: Colors.teal,
              areaAlpha: 0.2,
            ),
            size,
          );
          // A second series under the first, and one that is out of step
          // with it: both paint, neither throws.
          paintAt(
            SparklinePainter(
              values: values,
              color: Colors.teal,
              areaAlpha: 0.2,
              secondaryValues: [for (final v in values) v / 2],
              secondaryColor: Colors.amber,
            ),
            size,
          );
          paintAt(
            SparklinePainter(
              values: values,
              color: Colors.teal,
              secondaryValues: const [1, double.nan, 2],
              secondaryColor: Colors.amber,
            ),
            size,
          );
          paintAt(
            TimeSeriesPainter(
              geometry: TimeSeriesGeometry(
                size: size,
                start: start,
                end: end,
                minY: 0,
                maxY: 100,
                axisStyle: ink().axisLabel,
                scaler: TextScaler.noScaling,
                valueLabel: (v) => '${v.round()}%',
                timeLabel: (t) => '${t.hour}:00',
              ),
              points: series(count),
              color: Colors.teal,
              ink: ink(),
              markers: [
                ChartMarker(
                  start.add(const Duration(hours: 2)),
                  label: 'reset',
                ),
              ],
              guides: const [100],
              breakAfter: const Duration(minutes: 30),
              selected: count == 0 ? null : series(count).last,
            ),
            size,
          );
          paintAt(
            BarChartPainter(
              geometry: BarGeometry(
                size: size,
                bars: bars(count),
                axisStyle: ink().axisLabel,
                scaler: TextScaler.noScaling,
              ),
              bars: bars(count),
              color: Colors.teal,
              ink: ink(),
              selected: count == 0 ? null : 0,
            ),
            size,
          );
        });
      }
      test('meters at ${size.width}x${size.height}', () {
        for (final value in [0.0, 0.004, 0.5, 1.0, 1.7, double.nan]) {
          final fraction = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
          paintAt(
            LinearMeterPainter(
              value: fraction,
              marker: 0.4,
              color: Colors.teal,
              track: Colors.grey,
              markerColor: Colors.black,
              thickness: 6,
            ),
            size,
          );
          paintAt(
            RadialMeterPainter(
              value: fraction,
              marker: 1,
              color: Colors.teal,
              track: Colors.grey,
              markerColor: Colors.black,
              strokeWidth: 4,
            ),
            size,
          );
        }
      });
    }
  });

  group('as widgets', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      for (final width in [40.0, 200.0, 720.0]) {
        for (final count in [0, 1, 40]) {
          testWidgets('lay out at ${width}px, ${theme.brightness.name}, '
              '$count readings', (tester) async {
            final overflows = await pumpInBox(
              tester,
              width: width,
              theme: theme,
              textScale: 1.3,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    LinearMeter(
                      value: 0.62,
                      marker: 0.4,
                      color: Colors.teal,
                      semanticsLabel: '5-hour, 62% used',
                    ),
                    const RadialMeter(
                      value: 0.3,
                      color: Colors.teal,
                      semanticsLabel: 'ring',
                    ),
                    Sparkline(
                      values: [for (var i = 0; i < count; i++) i.toDouble()],
                      color: Colors.teal,
                      semanticsLabel: 'trend',
                    ),
                    TimeSeriesChart(
                      points: series(count),
                      start: start,
                      end: end,
                      color: Colors.teal,
                      semanticsLabel: 'series',
                      valueLabel: (v) => '${v.round()}%',
                      timeLabel: (t) => '${t.hour}:00',
                      markers: [ChartMarker(end, label: 'resets')],
                      guides: const [100],
                    ),
                    BarChart(
                      bars: bars(count),
                      color: Colors.teal,
                      semanticsLabel: 'bars',
                    ),
                    RankedBars(bars: bars(count), color: Colors.teal),
                  ],
                ),
              ),
            );
            expect(overflows, isEmpty);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });

  testWidgets('ranked bars with labels above keep the whole name and number '
      'in a narrow region at large text', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const name = 'household-budget-site';
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Scaffold(
            body: RankedBars(
              labelAbove: true,
              color: Colors.teal,
              bars: const [
                BarDatum(label: name, value: 184, valueLabel: r'$1.84'),
                BarDatum(label: 'karmashala', value: 42, valueLabel: r'$0.42'),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final label = tester.getRect(find.text(name));
    final value = tester.getRect(find.text(r'$1.84'));
    expect(label.bottom, lessThanOrEqualTo(value.top), reason: 'label above');
    for (final text in [name, r'$1.84', r'$0.42']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
      expect(paragraph.didExceedMaxLines, isFalse, reason: text);
    }
  });

  group('a sparkline with a second series', () {
    test('repaints when only that series changes', () {
      const before = SparklinePainter(
        values: [4, 8],
        color: Colors.teal,
        secondaryValues: [1, 2],
        secondaryColor: Colors.amber,
      );
      const same = SparklinePainter(
        values: [4, 8],
        color: Colors.teal,
        secondaryValues: [1, 2],
        secondaryColor: Colors.amber,
      );
      const moved = SparklinePainter(
        values: [4, 8],
        color: Colors.teal,
        secondaryValues: [1, 3],
        secondaryColor: Colors.amber,
      );
      expect(same.shouldRepaint(before), isFalse);
      expect(moved.shouldRepaint(before), isTrue);
    });

    testWidgets('lays out in a box that measures its content', (tester) async {
      final overflows = await pumpInBox(
        tester,
        width: 200,
        child: const IntrinsicWidth(
          child: Sparkline(
            values: [4, 8, 6],
            secondaryValues: [1, 5, 2],
            secondaryColor: Colors.amber,
            color: Colors.teal,
            semanticsLabel: 'stacked',
          ),
        ),
      );
      expect(overflows, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('every chart names itself to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpInBox(
      tester,
      width: 600,
      child: Column(
        children: [
          const LinearMeter(
            value: 0.62,
            color: Colors.teal,
            semanticsLabel: '5-hour window, 62% used',
          ),
          const RadialMeter(
            value: 0.2,
            color: Colors.teal,
            semanticsLabel: 'Weekly window, 20% used',
          ),
          const Sparkline(
            values: [1, 2, 3],
            color: Colors.teal,
            semanticsLabel: 'Rising over five hours',
          ),
          TimeSeriesChart(
            points: series(5),
            start: start,
            end: end,
            color: Colors.teal,
            semanticsLabel: '5-hour usage over time, peak 28%',
            valueLabel: (v) => '$v',
            timeLabel: (t) => '$t',
          ),
          BarChart(
            bars: bars(3),
            color: Colors.teal,
            semanticsLabel: 'Spent per day',
          ),
          const RankedBars(
            bars: [BarDatum(label: 'karmashala', value: 3, valueLabel: '3k')],
            color: Colors.teal,
          ),
        ],
      ),
    );
    for (final label in [
      '5-hour window, 62% used',
      'Weekly window, 20% used',
      'Rising over five hours',
      '5-hour usage over time, peak 28%',
      'Spent per day',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    expect(find.bySemanticsLabel(RegExp('karmashala')), findsOneWidget);
    semantics.dispose();
  });

  test('a narrow time series drops its axes, a wide one keeps them', () {
    TimeSeriesGeometry at(double width) => TimeSeriesGeometry(
      size: Size(width, 160),
      start: start,
      end: end,
      minY: 0,
      maxY: 100,
      axisStyle: const TextStyle(fontSize: 11),
      scaler: TextScaler.noScaling,
      valueLabel: (v) => '${v.round()}%',
      timeLabel: (t) => '${t.hour}:00',
    );
    expect(at(kChartCompactWidth - 1).compact, isTrue);
    expect(at(kChartCompactWidth - 1).yLabels, isEmpty);
    expect(at(kChartCompactWidth - 1).xLabels, isEmpty);
    expect(at(600).yLabels, hasLength(3));
    expect(at(600).xLabels, hasLength(2));
    expect(at(600).plot.left, greaterThan(0), reason: 'room for the labels');
  });

  test('bar labels thin out rather than collide', () {
    BarGeometry at(double width, int count) => BarGeometry(
      size: Size(width, 120),
      bars: bars(count),
      axisStyle: const TextStyle(fontSize: 11),
      scaler: TextScaler.noScaling,
    );
    expect(at(700, 3).stride, 1);
    final crowded = at(400, 30);
    expect(crowded.stride, greaterThan(1));
    expect(at(200, 30).labels, isEmpty, reason: 'compact: no labels at all');
    expect(at(700, 3).indexAt(10), 0);
    expect(at(700, 3).indexAt(699), 2);
    expect(at(700, 3).indexAt(-5), isNull);
  });

  testWidgets('hovering a time series explains the nearest reading', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 600,
      child: TimeSeriesChart(
        points: [
          TimeSeriesPoint(start, 10),
          TimeSeriesPoint(start.add(const Duration(hours: 4)), 55),
        ],
        start: start,
        end: end,
        color: Colors.teal,
        semanticsLabel: 'series',
        valueLabel: (v) => '${v.round()}% used',
        timeLabel: (t) => 'at ${t.hour}:00',
      ),
    );
    expect(find.byType(ChartTooltipCard), findsNothing);

    final chart = tester.getRect(find.byType(TimeSeriesChart));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(Offset(chart.right - 20, chart.center.dy));
    await tester.pump();
    expect(find.text('55% used'), findsOneWidget);
    expect(find.text('at 12:00'), findsOneWidget);

    await mouse.moveTo(Offset(chart.right + 50, chart.bottom + 50));
    await tester.pump();
    expect(find.byType(ChartTooltipCard), findsNothing);
  });

  testWidgets('a tap shows a bar\'s value, and a second tap hides it', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 600,
      child: const BarChart(
        bars: [
          BarDatum(label: 'Mon', value: 4, valueLabel: '4 points'),
          BarDatum(label: 'Tue', value: 9, valueLabel: '9 points'),
        ],
        color: Colors.teal,
        semanticsLabel: 'bars',
      ),
    );
    final chart = tester.getRect(find.byType(BarChart));
    final tue = Offset(chart.left + chart.width * 0.75, chart.center.dy);
    await tester.tapAt(tue);
    await tester.pump();
    expect(find.text('9 points'), findsOneWidget);
    await tester.tapAt(tue);
    await tester.pump();
    expect(find.text('9 points'), findsNothing);
  });

  group('motion', () {
    double painted(WidgetTester tester) {
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(LinearMeter),
          matching: find.byType(CustomPaint),
        ),
      );
      return (paint.painter! as LinearMeterPainter).value;
    }

    Future<void> pumpMeter(
      WidgetTester tester, {
      required double value,
      required bool reduced,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: LinearMeter(
              value: value,
              color: Colors.teal,
              semanticsLabel: 'meter',
            ),
          ),
        ),
      ),
    );

    testWidgets('a meter tweens to a new value', (tester) async {
      await pumpMeter(tester, value: 0.2, reduced: false);
      expect(painted(tester), 0.2, reason: 'the first value is not animated');
      await pumpMeter(tester, value: 0.8, reduced: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(painted(tester), inExclusiveRange(0.2, 0.8));
      await tester.pumpAndSettle();
      expect(painted(tester), 0.8);
    });

    testWidgets('and jumps when reduced motion is on', (tester) async {
      await pumpMeter(tester, value: 0.2, reduced: true);
      await pumpMeter(tester, value: 0.8, reduced: true);
      await tester.pump();
      expect(painted(tester), 0.8);
    });
  });
}
