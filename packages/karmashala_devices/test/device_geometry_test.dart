import 'package:karmashala_devices/src/domain/device_geometry.dart';
import 'package:karmashala_devices/src/domain/device_input.dart';
import 'package:test/test.dart';

const _screen = DeviceScreenSize(width: 1080, height: 2400);

void main() {
  group('widgetPointToDevice', () {
    test(
      'reproduces the emulator round trip verified against real hardware',
      () {
        // A Settings row whose real bounds were [891,275][1017,401].
        const WidgetBox box = (width: 405, height: 900);
        final mapped = widgetPointToDevice(
          local: (dx: 357.75, dy: 126.75),
          box: box,
          screen: _screen,
        );
        expect(mapped.x, 954);
        expect(mapped.y, 338);
      },
    );

    test('maps the corners exactly', () {
      const WidgetBox box = (width: 405, height: 900);
      expect(
        widgetPointToDevice(local: (dx: 0.0, dy: 0.0), box: box, screen: _screen),
        (x: 0, y: 0),
      );
      expect(
        widgetPointToDevice(
          local: (dx: 405, dy: 900),
          box: box,
          screen: _screen,
        ),
        (x: 1079, y: 2399),
        reason: 'the far edge must stay inside the screen',
      );
    });

    test('maps the centre to the centre at any box size', () {
      for (final box in const <WidgetBox>[
        (width: 405, height: 900),
        (width: 270, height: 600),
        (width: 810, height: 1800),
      ]) {
        final mapped = widgetPointToDevice(
          local: (dx: box.width / 2, dy: box.height / 2),
          box: box,
          screen: _screen,
        );
        expect(mapped.x, 540);
        expect(mapped.y, 1200);
      }
    });

    test('clamps points dragged outside the box', () {
      const WidgetBox box = (width: 405, height: 900);
      final mapped = widgetPointToDevice(
        local: (dx: -50, dy: 2000),
        box: box,
        screen: _screen,
      );
      expect(mapped.x, 0);
      expect(mapped.y, 2399);
    });

    test('is safe on a zero-sized box during the first layout', () {
      expect(
        widgetPointToDevice(
          local: (dx: 10, dy: 10),
          box: (width: 0.0, height: 0.0),
          screen: _screen,
        ),
        (x: 0, y: 0),
      );
    });

    test('handles a landscape screen', () {
      const landscape = DeviceScreenSize(width: 2400, height: 1080);
      final mapped = widgetPointToDevice(
        local: (dx: 450, dy: 100),
        box: (width: 900, height: 405),
        screen: landscape,
      );
      expect(mapped.x, 1200);
      expect(mapped.y, 267);
    });
  });

  group('swipeDurationFor', () {
    // The clamping is written against the same constants it clamps to, so these
    // pin the millisecond values that actually reach `adb shell input swipe`.
    test('the bounds are the millisecond values adb is handed', () {
      expect(kMinSwipeDuration, const Duration(milliseconds: 60));
      expect(kMaxSwipeDuration, const Duration(milliseconds: 1500));
    });

    test('passes an ordinary gesture through unchanged', () {
      // `input swipe` interpolates over the duration it is given, so the
      // duration IS the gesture's velocity.
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
      expect(kLongPressHoldDuration, const Duration(milliseconds: 700));
    });
  });

  group('widgetPointToFraction', () {
    // Gestures are carried as fractions because the two transports want the
    // same touch in different spaces: device pixels, and *video* pixels.
    test('the corners are 0 and 1 whatever the box size', () {
      const WidgetBox box = (width: 405, height: 900);
      expect(widgetPointToFraction(local: (dx: 0.0, dy: 0.0), box: box), (x: 0, y: 0));
      expect(widgetPointToFraction(local: (dx: 405, dy: 900), box: box), (
        x: 1.0,
        y: 1.0,
      ));
    });

    test('clamps a pointer dragged outside the picture', () {
      const WidgetBox box = (width: 405, height: 900);
      final out = widgetPointToFraction(
        local: (dx: -40, dy: 1400),
        box: box,
      );
      expect(out.x, 0.0);
      expect(out.y, 1.0);
    });

    test('is safe on a zero-sized box during the first layout', () {
      expect(
        widgetPointToFraction(local: (dx: 10, dy: 10), box: (width: 0.0, height: 0.0)),
        (x: 0, y: 0),
      );
    });
  });

  group('fractionToDevice', () {
    const video = DeviceScreenSize(width: 472, height: 1024);

    test('scales into whichever space it is handed', () {
      // 472x1024 is a real video size. Sending device pixels with that video
      // size declared is the mistake that makes touches silently vanish.
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
