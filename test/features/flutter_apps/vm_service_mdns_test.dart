import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/domain/vm_service_mdns.dart';

void main() {
  // Unchecked: written from flutter_tools' reader, never seen against a real
  // simulator on this machine. The test pins the shape, not a measurement.
  group('an iOS app advertisement (unchecked — no Mac here)', () {
    test('is the SRV port and the TXT auth code, together', () {
      final uri = vmServiceUriFromMdns(port: 57701, txt: 'authCode=AbCdEf=');
      expect(uri.toString(), 'http://127.0.0.1:57701/AbCdEf=/');
    });

    test('keeps a trailing slash the advertiser already put on', () {
      final uri = vmServiceUriFromMdns(port: 1, txt: 'authCode=t=/');
      expect(uri!.path, '/t=/');
    });

    test('finds the code among other TXT lines', () {
      final uri = vmServiceUriFromMdns(
        port: 1,
        txt: 'somethingElse=1\nauthCode=t=\nmore=2',
      );
      expect(uri!.path, '/t=/');
    });

    test('refuses an advertisement with no code rather than guessing one', () {
      expect(vmServiceUriFromMdns(port: 1, txt: ''), isNull);
      expect(vmServiceUriFromMdns(port: 1, txt: 'authCode='), isNull);
      expect(vmServiceUriFromMdns(port: 0, txt: 'authCode=t='), isNull);
    });

    test('names the service flutter attach queries', () {
      expect(kDartVmServiceMdnsName, '_dartVmService._tcp.local');
    });
  });
}
