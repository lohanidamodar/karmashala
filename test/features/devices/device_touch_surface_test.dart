import 'package:chitragupta/src/features/devices/domain/device_geometry.dart';
import 'package:chitragupta/src/features/devices/domain/device_input.dart';
import 'package:chitragupta/src/features/devices/presentation/device_touch_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 405x900 surface over a 1080x2400 device — the same pane size the Loop 27
/// coordinate mapping was verified at, so the expected numbers below are
/// comparable to that measurement.
const _paneSize = Size(405, 900);
const _screen = DeviceScreenSize(width: 1080, height: 2400);

typedef _Swipe = ({int fromX, int fromY, int toX, int toY, Duration duration});

void main() {
  ({int x, int y})? tapped;
  ({int x, int y})? longPressed;
  _Swipe? swiped;

  setUp(() {
    tapped = null;
    longPressed = null;
    swiped = null;
  });

  Future<void> pump(
    WidgetTester tester, {
    DeviceScreenSize? screen = _screen,
  }) async {
    // The default 800x600 test surface would squash a 405x900 pane to 600 tall
    // and every mapped coordinate with it.
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: _paneSize.width,
            height: _paneSize.height,
            child: DeviceTouchSurface(
              screen: screen,
              onTap: (x, y) => tapped = (x: x, y: y),
              onLongPress: (x, y) => longPressed = (x: x, y: y),
              onSwipe: (fromX, fromY, toX, toY, duration) => swiped = (
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                duration: duration,
              ),
              child: const ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ),
      ),
    );
  }

  /// The widget-local point that maps to a given device point, so tests can be
  /// written in device coordinates.
  Offset localFor(int deviceX, int deviceY) => Offset(
    deviceX / _screen.width * _paneSize.width,
    deviceY / _screen.height * _paneSize.height,
  );

  Offset globalFor(WidgetTester tester, Offset local) =>
      tester.getTopLeft(find.byType(DeviceTouchSurface)) + local;

  group('tap', () {
    testWidgets('reports the point in device pixels', (tester) async {
      await pump(tester);
      // The Loop 27 example: a Settings row centred at device (954, 338)
      // appears at (357.8, 126.8) in a 405x900 pane.
      await tester.tapAt(globalFor(tester, const Offset(357.8, 126.8)));
      expect(tapped, (x: 954, y: 338));
    });
  });

  group('long press', () {
    testWidgets('reports the point, which a plain onLongPress cannot', (
      tester,
    ) async {
      await pump(tester);
      await tester.longPressAt(globalFor(tester, localFor(540, 1200)));
      expect(longPressed, (x: 540, y: 1200));
      expect(swiped, isNull, reason: 'a long press is not a drag');
      expect(tapped, isNull, reason: 'a long press is not a tap');
    });
  });

  group('drag', () {
    testWidgets('reports both endpoints in device pixels', (tester) async {
      await pump(tester);
      await tester.timedDragFrom(
        globalFor(tester, localFor(540, 1800)),
        localFor(540, 600) - localFor(540, 1800),
        const Duration(milliseconds: 300),
      );
      expect(swiped, isNotNull);
      expect(swiped!.fromX, 540);
      expect(swiped!.fromY, 1800);
      expect(swiped!.toX, 540);
      expect(swiped!.toY, closeTo(600, 8));
      expect(tapped, isNull);
    });

    testWidgets('a slow drag and a flick get different durations', (
      tester,
    ) async {
      // This is the whole reason the duration is derived rather than fixed:
      // `input swipe` interpolates over the duration, so the duration is the
      // gesture's velocity.
      await pump(tester);
      final from = globalFor(tester, localFor(540, 1800));
      final offset = localFor(540, 900) - localFor(540, 1800);

      await tester.timedDragFrom(from, offset, const Duration(seconds: 1));
      final slow = swiped!.duration;

      await tester.timedDragFrom(
        from,
        offset,
        const Duration(milliseconds: 120),
      );
      final quick = swiped!.duration;

      expect(slow, greaterThan(quick));
      expect(slow, greaterThanOrEqualTo(const Duration(milliseconds: 800)));
      expect(quick, lessThanOrEqualTo(const Duration(milliseconds: 300)));
    });

    testWidgets('a very slow drag is capped, not passed through', (
      tester,
    ) async {
      await pump(tester);
      await tester.timedDragFrom(
        globalFor(tester, localFor(540, 1800)),
        localFor(540, 900) - localFor(540, 1800),
        const Duration(seconds: 6),
      );
      expect(swiped!.duration, kMaxSwipeDuration);
    });
  });

  group('no screen size', () {
    testWidgets('input is inert rather than mapping against nothing', (
      tester,
    ) async {
      await pump(tester, screen: null);
      await tester.tapAt(globalFor(tester, const Offset(100, 100)));
      await tester.longPressAt(globalFor(tester, const Offset(100, 100)));
      await tester.timedDragFrom(
        globalFor(tester, const Offset(100, 700)),
        const Offset(0, -400),
        const Duration(milliseconds: 300),
      );
      expect(tapped, isNull);
      expect(longPressed, isNull);
      expect(swiped, isNull);
    });
  });
}
