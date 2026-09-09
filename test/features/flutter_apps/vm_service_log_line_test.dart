import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/domain/vm_service_log_line.dart';

void main() {
  /// Captured 2026-09-09 from `adb -s emulator-5554 logcat -v threadtime`
  /// while `flutter run -d emulator-5554` launched a debug app on the
  /// `sambandha_test` AVD (Android 14, google_apis, x86_64). Verbatim,
  /// including the logcat prefix and the `flutter :` tag.
  const captured =
      '09-09 14:01:30.298  4419  4478 I flutter : The Dart VM service is '
      'listening on http://127.0.0.1:42771/nQyjZWDSaNM=/';

  group('the line the Dart VM prints to a device log', () {
    test('yields the device port and the auth token that came with it', () {
      final uri = vmServiceUriInDeviceLogLine(captured);

      expect(uri, isNotNull);
      expect(uri!.port, 42771);
      // The token is the half nothing outside the app can recompute, so it is
      // carried verbatim — trailing slash included, which the VM requires.
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
      // Measured 2026-09-09: `adb -s emulator-5554 forward tcp:0 tcp:42771`
      // answered 59152, and GET http://127.0.0.1:59152/nQyjZWDSaNM=/ was 200
      // while the same port with any other token was 403.
      final device = vmServiceUriInDeviceLogLine(captured)!;
      final host = vmServiceUriOnHost(device, 59152);

      expect(host.toString(), 'http://127.0.0.1:59152/nQyjZWDSaNM=/');
    });
  });
}
