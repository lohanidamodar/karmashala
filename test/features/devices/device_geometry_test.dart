import 'dart:ui';

import 'package:chitragupta/src/features/devices/domain/device_geometry.dart';
import 'package:chitragupta/src/features/devices/domain/device_input.dart';
import 'package:flutter_test/flutter_test.dart';

const _screen = DeviceScreenSize(width: 1080, height: 2400);

void main() {
  group('widgetPointToDevice', () {
    test(
      'reproduces the emulator round trip verified against real hardware',
      () {
        // A Settings row whose real bounds were [891,275][1017,401].
        const box = Size(405, 900);
        final mapped = widgetPointToDevice(
          local: const Offset(357.75, 126.75),
          box: box,
          screen: _screen,
        );
        expect(mapped.x, 954);
        expect(mapped.y, 338);
      },
    );

    test('maps the corners exactly', () {
      const box = Size(405, 900);
      expect(
        widgetPointToDevice(local: Offset.zero, box: box, screen: _screen),
        (x: 0, y: 0),
      );
      expect(
        widgetPointToDevice(
          local: const Offset(405, 900),
          box: box,
          screen: _screen,
        ),
        (x: 1079, y: 2399),
        reason: 'the far edge must stay inside the screen',
      );
    });

    test('maps the centre to the centre at any box size', () {
      for (final box in [
        const Size(405, 900),
        const Size(270, 600),
        const Size(810, 1800),
      ]) {
        final mapped = widgetPointToDevice(
          local: Offset(box.width / 2, box.height / 2),
          box: box,
          screen: _screen,
        );
        expect(mapped.x, 540);
        expect(mapped.y, 1200);
      }
    });

    test('clamps points dragged outside the box', () {
      const box = Size(405, 900);
      final mapped = widgetPointToDevice(
        local: const Offset(-50, 2000),
        box: box,
        screen: _screen,
      );
      expect(mapped.x, 0);
      expect(mapped.y, 2399);
    });

    test('is safe on a zero-sized box during the first layout', () {
      expect(
        widgetPointToDevice(
          local: const Offset(10, 10),
          box: Size.zero,
          screen: _screen,
        ),
        (x: 0, y: 0),
      );
    });

    test('handles a landscape screen', () {
      const landscape = DeviceScreenSize(width: 2400, height: 1080);
      final mapped = widgetPointToDevice(
        local: const Offset(450, 100),
        box: const Size(900, 405),
        screen: landscape,
      );
      expect(mapped.x, 1200);
      expect(mapped.y, 267);
    });
  });

  group('swipeDurationFor', () {
    test('passes an ordinary gesture through unchanged', () {
      // `input swipe` interpolates over the duration it is given, so the
      // duration IS the gesture's velocity: a fixed value would make a flick
      // and a slow drag scroll by the same amount.
      expect(
        swipeDurationFor(const Duration(milliseconds: 400)),
        const Duration(milliseconds: 400),
      );
    });

    test('raises an implausibly quick flick to the floor', () {
      expect(swipeDurationFor(Duration.zero), kMinSwipeDuration);
      expect(
        swipeDurationFor(const Duration(milliseconds: 10)),
        kMinSwipeDuration,
      );
    });

    test('caps a long drag, which would otherwise block for that long', () {
      expect(swipeDurationFor(const Duration(seconds: 30)), kMaxSwipeDuration);
    });

    test('the long-press hold clears Android own 500 ms threshold', () {
      expect(
        kLongPressHoldDuration,
        greaterThan(const Duration(milliseconds: 500)),
      );
    });
  });

  group('widgetPointToFraction', () {
    // Gestures are carried as fractions because the two transports want the
    // same touch in different spaces: `adb shell input` in device pixels,
    // scrcpy's control socket in *video* pixels. Converting once, late, keeps
    // one mapping rather than two.
    test('the corners are 0 and 1 whatever the box size', () {
      const box = Size(405, 900);
      expect(widgetPointToFraction(local: Offset.zero, box: box), (x: 0, y: 0));
      expect(widgetPointToFraction(local: const Offset(405, 900), box: box), (
        x: 1.0,
        y: 1.0,
      ));
    });

    test('clamps a pointer dragged outside the picture', () {
      const box = Size(405, 900);
      final out = widgetPointToFraction(
        local: const Offset(-40, 1400),
        box: box,
      );
      expect(out.x, 0.0);
      expect(out.y, 1.0);
    });

    test('is safe on a zero-sized box during the first layout', () {
      expect(
        widgetPointToFraction(local: const Offset(10, 10), box: Size.zero),
        (x: 0, y: 0),
      );
    });
  });

  group('fractionToDevice', () {
    const video = DeviceScreenSize(width: 472, height: 1024);

    test('scales into whichever space it is handed', () {
      // 472x1024 is a real video size: scrcpy scaled a 1080x2340 phone down to
      // max_size=1024. Sending device pixels with that video size declared is
      // the mistake that makes touches silently vanish.
      expect(fractionToDevice(fx: 0.5, fy: 0.25, screen: video), (
        x: 236,
        y: 256,
      ));
    });

    test('never lands one pixel past the edge', () {
      expect(fractionToDevice(fx: 1.0, fy: 1.0, screen: video), (
        x: 471,
        y: 1023,
      ));
    });

    test('survives an empty screen without dividing by anything', () {
      expect(
        fractionToDevice(
          fx: 0.5,
          fy: 0.5,
          screen: const DeviceScreenSize(width: 0, height: 0),
        ),
        (x: 0, y: 0),
      );
    });
  });
}
