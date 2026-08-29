import 'package:chitragupta/src/features/devices/data/device_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseForwardedPort', () {
    test('reads the port adb allocated for tcp:0', () {
      expect(parseForwardedPort('54321\n'), 54321);
    });

    test('ignores surrounding chatter', () {
      expect(
        parseForwardedPort('* daemon started successfully\n49152\n'),
        49152,
      );
    });

    test('returns null when adb printed no port', () {
      expect(parseForwardedPort(''), isNull);
      expect(parseForwardedPort('error: device offline'), isNull);
    });
  });
}
