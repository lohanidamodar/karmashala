import 'package:karmashala/src/features/devices/data/device_gesture_sink.dart';
import 'package:karmashala/src/features/devices/presentation/device_touch_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 405x900 surface, the same pane size Loop 27 verified its coordinate
/// mapping at, so the fractions below are comparable to that measurement.
const _paneSize = Size(405, 900);

/// One reported pointer event, recorded so a test can assert the whole
/// sequence rather than just its endpoints — the sequence *is* the feature.
typedef _Event = ({String kind, int pointer, double fx, double fy});

class _RecordingSink implements DeviceGestureSink {
  final List<_Event> events = [];

  @override
  DeviceGestureTransport get transport => DeviceGestureTransport.scrcpyControl;

  @override
  void pointerDown(int pointer, double fx, double fy) =>
      events.add((kind: 'down', pointer: pointer, fx: fx, fy: fy));

  @override
  void pointerMove(int pointer, double fx, double fy) =>
      events.add((kind: 'move', pointer: pointer, fx: fx, fy: fy));

  @override
  void pointerUp(int pointer, double fx, double fy, Duration held) =>
      events.add((kind: 'up', pointer: pointer, fx: fx, fy: fy));

  @override
  void pointerCancel(int pointer) =>
      events.add((kind: 'cancel', pointer: pointer, fx: 0, fy: 0));

  List<String> get kinds => [for (final e in events) e.kind];
}

void main() {
  late _RecordingSink sink;

  setUp(() => sink = _RecordingSink());

  Future<void> pump(
    WidgetTester tester, {
    bool withSink = true,
    bool pinchWithModifier = true,
  }) async {
    // The default 800x600 test surface would squash a 405x900 pane.
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: _paneSize.width,
            height: _paneSize.height,
            child: DeviceTouchSurface(
              sink: withSink ? sink : null,
              pinchWithModifier: pinchWithModifier,
              child: const ColoredBox(color: Color(0xFF000000)),
            ),
          ),
        ),
      ),
    );
  }

  Offset globalAt(WidgetTester tester, double fx, double fy) =>
      tester.getTopLeft(find.byType(DeviceTouchSurface)) +
      Offset(fx * _paneSize.width, fy * _paneSize.height);

  group('a drag', () {
    testWidgets('reports every intermediate move, not just the endpoints', (
      tester,
    ) async {
      await pump(tester);
      final gesture = await tester.startGesture(globalAt(tester, 0.5, 0.8));
      for (var i = 1; i <= 8; i++) {
        await gesture.moveTo(globalAt(tester, 0.5, 0.8 - 0.05 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();

      // This is the whole point of Loop 36. A gesture recogniser would have
      // reported one summary; the device needs the motion as it happens.
      expect(sink.kinds.first, 'down');
      expect(sink.kinds.last, 'up');
      expect(sink.kinds.where((k) => k == 'move').length, 8);
    });

    testWidgets('the first move is not swallowed by touch slop', (
      tester,
    ) async {
      await pump(tester);
      final gesture = await tester.startGesture(globalAt(tester, 0.5, 0.5));
      // Two pixels: far below the ~18 px slop a GestureDetector insists on.
      await gesture.moveBy(const Offset(0, -2));
      await tester.pump();
      expect(sink.kinds, ['down', 'move']);
      await gesture.up();
    });

    testWidgets('positions are fractions of the picture', (tester) async {
      await pump(tester);
      await tester.tapAt(globalAt(tester, 0.25, 0.75));
      expect(sink.events.first.fx, closeTo(0.25, 0.005));
      expect(sink.events.first.fy, closeTo(0.75, 0.005));
    });
  });

  group('pointer ids', () {
    testWidgets('two fingers get two distinct ids', (tester) async {
      await pump(tester);
      final a = await tester.startGesture(globalAt(tester, 0.2, 0.2));
      final b = await tester.startGesture(globalAt(tester, 0.8, 0.8));
      await a.moveTo(globalAt(tester, 0.3, 0.3));
      await b.moveTo(globalAt(tester, 0.7, 0.7));
      await a.up();
      await b.up();
      await tester.pump();

      final ids = sink.events.map((e) => e.pointer).toSet();
      expect(ids, {0, 1});
    });

    testWidgets('an id is recycled once its finger lifts', (tester) async {
      await pump(tester);
      await tester.tapAt(globalAt(tester, 0.2, 0.2));
      await tester.tapAt(globalAt(tester, 0.8, 0.8));
      // Flutter's own pointer numbers keep climbing; scrcpy's PointersState is
      // a fixed-size table, so ours must not.
      expect(sink.events.map((e) => e.pointer).toSet(), {0});
    });
  });

  group('Ctrl-drag pinch', () {
    testWidgets('adds a second pointer mirrored about the centre', (
      tester,
    ) async {
      await pump(tester);
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      addTearDown(() => simulateKeyUpEvent(LogicalKeyboardKey.controlLeft));

      final gesture = await tester.startGesture(globalAt(tester, 0.3, 0.3));
      await gesture.moveTo(globalAt(tester, 0.4, 0.4));
      await gesture.up();
      await tester.pump();

      final downs = sink.events.where((e) => e.kind == 'down').toList();
      expect(downs.length, 2);
      expect(downs[0].fx, closeTo(0.3, 0.01));
      expect(downs[1].fx, closeTo(0.7, 0.01));
      expect(downs[1].fy, closeTo(0.7, 0.01));
      expect(sink.events.where((e) => e.kind == 'up').length, 2);
    });

    testWidgets('is off without the modifier', (tester) async {
      await pump(tester);
      await tester.tapAt(globalAt(tester, 0.3, 0.3));
      expect(sink.events.where((e) => e.kind == 'down').length, 1);
    });
  });

  testWidgets('no sink means no input at all', (tester) async {
    await pump(tester, withSink: false);
    await tester.tapAt(globalAt(tester, 0.5, 0.5));
    expect(sink.events, isEmpty);
  });
}
