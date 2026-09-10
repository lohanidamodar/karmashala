/// Regenerates `remote_test_vectors.json`. Run it only when the key schedule or
/// the sealed frame format is meant to change — the committed vectors are what
/// stop the host and the companion drifting apart, so a diff here is a protocol
/// change.
///
/// ```
/// dart run test/remote/generate_vectors.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

const _secretHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const _hostIdHex = '11111111222222223333333344444444';
const _deviceIdHex = 'aaaaaaaabbbbbbbbccccccccdddddddd';
const _nonceHexes = [
  '303132333435363738393a3b3c3d3e3f4041424344454647',
  '505152535455565758595a5b5c5d5e5f6061626364656667',
];
const _typedCodeSecretHex = '000102030405060708090a0b0c0d0e0f10111213';

Future<void> main() async {
  final secret = _fromHex(_secretHex);
  final hostId = DeviceId.parse(_hostIdHex);
  final deviceId = DeviceId.parse(_deviceIdHex);
  final deviceKey = await deriveDeviceKey(
    pairingSecret: secret,
    hostId: hostId,
    deviceId: deviceId,
  );

  final generations = <Map<String, Object?>>[];
  for (final generation in [0, 1, 7, 1000]) {
    generations.add({
      'generation': generation,
      'rendezvous': (await rendezvousFor(deviceKey, generation)).value,
      'hostToDevice': _hex(
        (await deriveDirectionKey(
          deviceKey,
          ChannelDirection.hostToDevice,
          generation: generation,
        )).bytes,
      ),
      'deviceToHost': _hex(
        (await deriveDirectionKey(
          deviceKey,
          ChannelDirection.deviceToHost,
          generation: generation,
        )).bytes,
      ),
    });
  }

  final frames = <Map<String, Object?>>[];
  for (final role in ChannelRole.values) {
    var nonceIndex = 0;
    final channel = await SealedChannel.forDevice(
      deviceKey: deviceKey,
      role: role,
      nonceSource: () => _fromHex(_nonceHexes[nonceIndex++]),
    );
    for (final plaintext in [
      utf8.encode('{"v":1,"seq":0,"t":"sessions.list","p":{}}'),
      Uint8List(0),
    ]) {
      final sequence = channel.nextSendSequence;
      final nonce = _nonceHexes[nonceIndex];
      frames.add({
        'generation': 0,
        'role': role.name,
        'sequence': sequence,
        'nonce': nonce,
        'plaintext': _hex(plaintext),
        'frame': _hex(await channel.seal(plaintext)),
      });
    }
  }

  final vectors = <String, Object?>{
    'note':
        'Committed so the host and the companion cannot drift. Regenerate with '
        'test/features/remote/generate_vectors.dart.',
    'hkdf': 'HKDF-SHA256',
    'salt': utf8.decode(kKeyScheduleSalt),
    'aead':
        'XChaCha20-Poly1305, frame = nonce(24) || ciphertext || mac(16), '
        'sealed plaintext = uint64be(sequence) || payload, '
        'aad = the direction label',
    'pairingSecret': _secretHex,
    'hostId': _hostIdHex,
    'deviceId': _deviceIdHex,
    'deviceKey': _hex(deviceKey.bytes),
    'generations': generations,
    'frames': frames,
    // The typed-code chain: code secret → pairing secret → rendezvous and
    // confirm key. Both ends must derive these identically.
    'pairingCode': await _pairingCodeVectors(),
  };

  final file = File('test/remote/remote_test_vectors.json');
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(vectors)}\n',
  );
  stdout.writeln('wrote ${file.path}');
}

Future<Map<String, Object?>> _pairingCodeVectors() async {
  final codeSecret = _fromHex(_typedCodeSecretHex);
  final pairingSecret = await derivePairingSecret(codeSecret);
  return {
    'codeSecret': _typedCodeSecretHex,
    'code': PairingCode.encode(codeSecret),
    'pairingSecret': _hex(pairingSecret.bytes),
    'pairingRendezvous': (await derivePairingRendezvous(
      pairingSecret.bytes,
    )).value,
    'confirmKey': _hex(
      (await derivePairingConfirmKey(pairingSecret.bytes)).bytes,
    ),
  };
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
