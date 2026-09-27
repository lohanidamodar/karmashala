import 'package:test/test.dart';
import 'package:karmashala_core/logging.dart';

/// The two cases `karmashala_devices`' `wireless_pairing_test` left behind:
/// they are about `LogRedactor`, which is the app's logging layer rather than
/// anything a device driver owns, but the payloads they redact are the pairing
/// flow's — so they stay here, beside the pairing they protect.
void main() {
  group('the log redactor', () {
    test('a QR payload does not carry its password into the log', () {
      final line = LogRedactor().apply(
        'pairing invite WIFI:T:ADB;S:karmashala-A1B2C3D4;P:p4ssw0rdp4ss;;',
      );
      expect(line, isNot(contains('p4ssw0rdp4ss')));
      expect(
        line,
        contains('karmashala-A1B2C3D4'),
        reason: 'the service name is how the flow is followed in a log',
      );
    });

    test('a pairing code written with a space is still a pairing code', () {
      expect(
        LogRedactor().apply('pairing code: 123456'),
        isNot(contains('123456')),
      );
    });
  });
}
