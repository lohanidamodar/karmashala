/// The key schedule: one pairing secret becomes a device key, two direction
/// keys and a rotating rendezvous id.
///
/// Every derivation is HKDF-SHA256 with the same salt and a distinct `info`
/// label, so no two outputs can ever collide. Loop A supplies the pairing
/// secret (32 bytes from the QR code, or the SPAKE2 output of a short code);
/// nothing here ever touches the network.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protocol.dart';

/// Shared HKDF salt. Fixed and public — it separates this protocol's key
/// material from any other use of the same secret.
final Uint8List kKeyScheduleSalt = Uint8List.fromList(
  'chitragupta/remote/v1'.codeUnits,
);

/// Shortest pairing secret the schedule accepts. The QR path uses 32 bytes.
const int kMinPairingSecretBytes = 16;

/// Length of every symmetric key the schedule produces.
const int kDeviceKeyBytes = 32;

/// How far ahead a joining end may probe for the host's rendezvous when the two
/// counters have drifted apart.
const int kRendezvousProbeWindow = 8;

/// Which way a frame travels. Each direction gets its own key, so a frame can
/// never be replayed back at its sender.
enum ChannelDirection {
  hostToDevice('dir:host->device'),
  deviceToHost('dir:device->host');

  const ChannelDirection(this.label);

  /// The HKDF `info` label, also used as the AEAD associated data.
  final String label;

  ChannelDirection get reversed => this == hostToDevice
      ? ChannelDirection.deviceToHost
      : ChannelDirection.hostToDevice;
}

final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: kDeviceKeyBytes);

/// Derives the long-lived key for one paired phone.
///
/// The two device ids are bound in a fixed order (host first) so both ends
/// compute the same key without negotiating anything.
Future<SecretKeyData> deriveDeviceKey({
  required List<int> pairingSecret,
  required DeviceId hostId,
  required DeviceId deviceId,
}) async {
  if (pairingSecret.length < kMinPairingSecretBytes) {
    throw ArgumentError.value(
      pairingSecret.length,
      'pairingSecret',
      'must be at least $kMinPairingSecretBytes bytes',
    );
  }
  return _derive(
    ikm: pairingSecret,
    info: [...'device-key'.codeUnits, ...hostId.bytes, ...deviceId.bytes],
    length: kDeviceKeyBytes,
  );
}

/// Derives the sealing key for one direction of a device's channel, for
/// connection [generation] — the same counter [rendezvousFor] uses.
///
/// Binding the generation is what lets sequence numbers restart at zero on a
/// new connection: old frames cannot be replayed into it, because the key they
/// were sealed under is gone. Within one generation the key is stable, so a
/// reconnect resumes the same sequence.
Future<SecretKeyData> deriveDirectionKey(
  SecretKeyData deviceKey,
  ChannelDirection direction, {
  int generation = 0,
}) async {
  if (generation < 0) {
    throw ArgumentError.value(generation, 'generation', 'must not be negative');
  }
  return _derive(
    ikm: deviceKey.bytes,
    info: [...direction.label.codeUnits, ..._uint64be(generation)],
    length: kDeviceKeyBytes,
  );
}

/// The relay path this device uses for connection [counter].
///
/// Pseudorandom in the device key, so the relay sees an unrelated 16-byte id
/// every time and cannot link one device's connections to each other. Both ends
/// derive it from the same key, so no id is ever transmitted.
///
/// Both ends persist the counter and bump it after a connection pairs. If they
/// drift — the host missed a companion's attempt, say — the joining end walks
/// [rendezvousWindow] forward until it finds the host.
Future<RendezvousId> rendezvousFor(SecretKeyData deviceKey, int counter) async {
  if (counter < 0) {
    throw ArgumentError.value(counter, 'counter', 'must not be negative');
  }
  final key = await _derive(
    ikm: deviceKey.bytes,
    info: ['rendezvous'.codeUnits, _uint64be(counter)].expand((x) => x),
    length: RendezvousId.lengthInBytes,
  );
  return RendezvousId(Uint8List.fromList(key.bytes));
}

/// The rendezvous ids for `counter .. counter + window - 1`, in order.
Future<List<RendezvousId>> rendezvousWindow(
  SecretKeyData deviceKey,
  int counter, {
  int window = kRendezvousProbeWindow,
}) async {
  if (window < 1) {
    throw ArgumentError.value(window, 'window', 'must be at least 1');
  }
  return [
    for (var i = 0; i < window; i++)
      await rendezvousFor(deviceKey, counter + i),
  ];
}

Future<SecretKeyData> _derive({
  required List<int> ikm,
  required Iterable<int> info,
  required int length,
}) async {
  final hkdf = length == kDeviceKeyBytes
      ? _hkdf
      : Hkdf(hmac: Hmac.sha256(), outputLength: length);
  return hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: kKeyScheduleSalt,
    info: info.toList(growable: false),
  );
}

Uint8List _uint64be(int value) {
  final out = Uint8List(8);
  ByteData.view(out.buffer).setUint64(0, value);
  return out;
}
