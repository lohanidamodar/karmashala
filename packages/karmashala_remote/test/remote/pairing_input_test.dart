import 'package:karmashala_remote/pairing.dart';
import 'package:test/test.dart';

/// The sniff the pairing screen runs on what was scanned or pasted.
void main() {
  const payload = '{"secret":"s3cret"}';
  final typedCode = PairingCode.encode(List<int>.generate(20, (i) => i));

  test('tells payloads, typed codes and junk apart', () {
    expect(classifyPairingInput(payload), PairingInputKind.payload);
    expect(classifyPairingInput(' $payload '), PairingInputKind.payload);
    expect(classifyPairingInput(typedCode), PairingInputKind.typedCode);
    expect(
      classifyPairingInput(typedCode.toLowerCase().replaceAll('-', ' ')),
      PairingInputKind.typedCode,
    );
    expect(
      classifyPairingInput('https://example.com/qr'),
      PairingInputKind.unrecognised,
    );
    expect(classifyPairingInput('ABCD1234'), PairingInputKind.unrecognised);
    expect(classifyPairingInput(''), PairingInputKind.unrecognised);
  });
}
