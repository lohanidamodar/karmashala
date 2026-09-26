import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

void main() {
  group('a change is a third kind of target', () {
    test('it parses by name and unknown values still fall back', () {
      expect(
        VerificationTargetKind.parse('change'),
        VerificationTargetKind.change,
      );
      expect(
        VerificationTargetKind.parse('teleport'),
        VerificationTargetKind.browser,
      );
    });

    test('it is neither a browser nor a device, and says so', () {
      const target = VerificationTarget.change();
      expect(target.kind, VerificationTargetKind.change);
      expect(target.isBrowser, isFalse);
      expect(target.isDevice, isFalse);
      expect(target.label, isNotEmpty);
    });
  });
}
