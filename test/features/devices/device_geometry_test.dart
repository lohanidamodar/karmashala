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
}
