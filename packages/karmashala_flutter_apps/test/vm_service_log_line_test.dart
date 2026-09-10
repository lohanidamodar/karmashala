import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

void main() {
  /// Captured verbatim 2026-09-09 from `adb logcat -v threadtime`, logcat
  /// prefix and `flutter :` tag included.
  const captured =
      '09-09 14:01:30.298  4419  4478 I flutter : The Dart VM service is '
      'listening on http://127.0.0.1:42771/nQyjZWDSaNM=/';

  group('the line the Dart VM prints to a device log', () {
    test('yields the device port and the auth token that came with it', () {
      final uri = vmServiceUriInDeviceLogLine(captured);

      expect(uri, isNotNull);
      expect(uri!.port, 42771);
      // The token is carried verbatim, trailing slash included.
      expect(uri.path, '/nQyjZWDSaNM=/');
      expect(uri.host, '127.0.0.1');
      expect(uri.scheme, 'http');
    });

    test('reads the scheme-less form flutter_tools also accepts', () {
      final uri = vmServiceUriInDeviceLogLine(
        'I flutter : The Dart VM service is listening on //127.0.0.1:8181/tok=/',
      );
      expect(uri, isNotNull);
      expect(uri!.scheme, 'http');
      expect(uri.port, 8181);
      expect(uri.path, '/tok=/');
    });

    test('puts back a trailing slash the VM answers 403 without', () {
      final uri = vmServiceUriInDeviceLogLine(
        'I flutter : The Dart VM service is listening on http://127.0.0.1:1/t=',
      );
      expect(uri!.path, '/t=/');
    });

    test('is not fooled by an ordinary log line', () {
      expect(
        vmServiceUriInDeviceLogLine(
          '09-09 14:01:30.081 759 890 D EGL_emulation: app_time_stats: avg=5ms',
        ),
        isNull,
      );
      expect(
        vmServiceUriInDeviceLogLine(
          'I flutter : listening on http://127.0.0.1:42771/nQyjZWDSaNM=/',
        ),
        isNull,
      );
    });

    test('refuses an address with no port, which is not one the VM printed', () {
      expect(
        vmServiceUriInDeviceLogLine(
          'I flutter : The Dart VM service is listening on http://example.com/t=/',
        ),
        isNull,
      );
    });
  });

  group('the same service through an adb forward', () {
    test('moves the port and keeps the token', () {
      // Measured 2026-09-09: the forwarded port answered 200 for this token
      // and 403 for any other.
      final device = vmServiceUriInDeviceLogLine(captured)!;
      final host = vmServiceUriOnHost(device, 59152);

      expect(host.toString(), 'http://127.0.0.1:59152/nQyjZWDSaNM=/');
    });
  });
}
