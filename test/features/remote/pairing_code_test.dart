/// The typed pairing code: base32 form, forgiving decode, the sniff, and the
/// committed derivation chain (code secret → pairing secret → rendezvous +
/// confirm key) that both ends must compute identically.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/features/remote/pairing/pairing_code.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_payload.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/remote/transport/key_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final secret = Uint8List.fromList(List<int>.generate(20, (i) => i));

  group('base32', () {
    test('matches RFC 4648 on whole blocks', () {
      // BASE32("fooba") = MZXW6YTB — the RFC's own vector, unpadded.
      expect(PairingCode.base32Encode(utf8.encode('fooba')), 'MZXW6YTB');
      expect(PairingCode.base32Decode('MZXW6YTB'), utf8.encode('fooba'));
      expect(PairingCode.base32Encode(const []), '');
    });

    test('refuses junk characters and ragged lengths', () {
      expect(PairingCode.base32Decode('MZXW6YT1'), isNull, reason: 'no 1');
      expect(PairingCode.base32Decode('MZXW6YT'), isNull, reason: '7 chars');
    });
  });

  group('the typed code', () {
    test('is 32 characters in eight groups of four', () {
      final code = PairingCode.encode(secret);
      expect(code.replaceAll('-', '').length, kPairingCodeChars);
      expect(code.split('-'), hasLength(8));
      for (final group in code.split('-')) {
        expect(group.length, kPairingCodeGroup);
      }
    });

    test('round-trips, forgiving case, spaces and dashes', () {
      final code = PairingCode.encode(secret);
      expect(PairingCode.tryDecode(code), secret);
      expect(PairingCode.tryDecode(code.toLowerCase()), secret);
      expect(PairingCode.tryDecode(code.replaceAll('-', ' ')), secret);
      expect(PairingCode.tryDecode(' ${code.replaceAll('-', '')} '), secret);
    });

    test('refuses anything that is not exactly a code', () {
      expect(PairingCode.tryDecode(''), isNull);
      expect(PairingCode.tryDecode('ABCD1234'), isNull, reason: 'too short');
      expect(PairingCode.tryDecode('{"secret":"x"}'), isNull);
      expect(
        PairingCode.tryDecode('${'A' * 31}1'),
        isNull,
        reason: '1 is not in the alphabet',
      );
      expect(PairingCode.looksLike(PairingCode.encode(secret)), isTrue);
      expect(PairingCode.looksLike('https://example.com'), isFalse);
    });

    test('encode refuses the wrong number of bytes', () {
      expect(() => PairingCode.encode(Uint8List(19)), throwsArgumentError);
    });
  });

  group('the derivation chain', () {
    test('is deterministic and every output is distinct', () async {
      final pairingSecret = await derivePairingSecret(secret);
      final again = await derivePairingSecret(secret);
      expect(pairingSecret.bytes, again.bytes);
      expect(pairingSecret.bytes, hasLength(kDeviceKeyBytes));

      final rendezvous = await derivePairingRendezvous(pairingSecret.bytes);
      final confirmKey = await derivePairingConfirmKey(pairingSecret.bytes);
      expect(rendezvous.bytes, hasLength(RendezvousId.lengthInBytes));
      expect(confirmKey.bytes, isNot(pairingSecret.bytes));
      expect(_toHex(rendezvous.bytes), isNot(_toHex(confirmKey.bytes)));
    });

    test('a different code lands on an unrelated rendezvous', () async {
      final a = await derivePairingRendezvous(
        (await derivePairingSecret(secret)).bytes,
      );
      final b = await derivePairingRendezvous(
        (await derivePairingSecret(Uint8List(20))).bytes,
      );
      expect(a.value, isNot(b.value));
    });

    test('the committed vectors still hold', () async {
      final vectors =
          jsonDecode(
                File(
                  'test/features/remote/remote_test_vectors.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final pairing = vectors['pairingCode']! as Map<String, Object?>;
      final codeSecret = _hex(pairing['codeSecret']! as String);

      expect(PairingCode.encode(codeSecret), pairing['code']);
      final pairingSecret = await derivePairingSecret(codeSecret);
      expect(_toHex(pairingSecret.bytes), pairing['pairingSecret']);
      expect(
        (await derivePairingRendezvous(pairingSecret.bytes)).value,
        pairing['pairingRendezvous'],
      );
      expect(
        _toHex((await derivePairingConfirmKey(pairingSecret.bytes)).bytes),
        pairing['confirmKey'],
      );
    });
  });

  group('generateWithCode', () {
    test('roots the payload in the typed code: secret and rendezvous both '
        'derive from it, and the QR text stays payload-shaped', () async {
      final payload = await PairingPayload.generateWithCode(
        relay: Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: CapabilitySet.all,
      );

      final typed = payload.typedSecret!;
      expect(typed, hasLength(kTypedCodeSecretBytes));
      final derived = await derivePairingSecret(typed);
      expect(payload.secret, derived.bytes);
      expect(
        payload.rendezvous,
        await derivePairingRendezvous(derived.bytes),
        reason: 'a typed-code phone must find the same rendezvous',
      );

      // The QR carries the same fields as ever — and never the typed secret.
      final decoded = PairingPayload.decode(payload.encode());
      expect(decoded.secret, payload.secret);
      expect(decoded.rendezvous, payload.rendezvous);
      expect(decoded.typedSecret, isNull);
      expect(payload.encode().contains(PairingCode.encode(typed)), isFalse);
    });

    test('a pre-existing payload (random rendezvous, 32-byte secret) still '
        'decodes', () {
      // The exact JSON shape loop 70's desktop painted.
      final old = PairingPayload.generate(
        relay: Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: CapabilitySet.all,
      );
      final decoded = PairingPayload.decode(old.encode());
      expect(decoded.secret, old.secret);
      expect(decoded.typedSecret, isNull);
    });
  });
}
