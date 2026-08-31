/// The phone's side of pairing: scan payload → derive key → sealed confirm
/// round-trip → persist. Pure Dart; the companion UI (another loop) owns the
/// camera and merely hands the scanned string here.
library;

import 'dart:async';
import 'dart:typed_data';

import '../pairing/pairing_payload.dart';
import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import 'companion_store.dart';

/// Pairing failed; [message] is safe to show the user.
class CompanionPairingException implements Exception {
  const CompanionPairingException(this.message);

  final String message;

  @override
  String toString() => 'CompanionPairingException: $message';
}

/// Turns a scanned [PairingPayload] into a stored [CompanionPairing].
class CompanionPairingClient {
  CompanionPairingClient({
    required this.store,
    DeviceId? deviceId,
    this.deviceName = 'Companion',
  }) : deviceId = deviceId ?? DeviceId.generate();

  final CompanionStore store;

  /// This phone's identity, minted here on first pairing.
  final DeviceId deviceId;

  /// What the host's device list will call this phone.
  final String deviceName;

  /// Pairs against [payload].
  ///
  /// Dials the payload's relay unless [transport] supplies a link — the LAN
  /// path when discovery found the host, or a loopback in tests. A transport
  /// this method dialled it also closes; a supplied one stays the caller's.
  /// [onConfirm] fires when the host's sealed confirm opens — the moment the
  /// desktop is provably found — before the ack/done round-trip finishes.
  Future<CompanionPairing> pair(
    PairingPayload payload, {
    RemoteTransport? transport,
    Duration timeout = const Duration(seconds: 30),
    void Function(String hostName, CapabilitySet capabilities)? onConfirm,
  }) async {
    if (!kSupportedVersions.contains(payload.version)) {
      throw const CompanionPairingException(
        'this host speaks a newer protocol — update the app',
      );
    }
    final ownsTransport = transport == null;
    final link =
        transport ??
        RelayTransport.connect(
          relay: payload.relay,
          rendezvous: payload.rendezvous,
        );
    final frames = StreamIterator<Uint8List>(link.frames);
    try {
      final key = await deriveDeviceKey(
        pairingSecret: payload.secret,
        hostId: payload.hostId,
        deviceId: deviceId,
      );
      final channel = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.companion,
      );

      link.send(LinkHello(payload.rendezvous).encode());
      link.send(PairHello(deviceId: deviceId, name: deviceName).encode());

      final confirm = await _awaitSealed(
        frames,
        channel,
        PairingMessage.confirm,
        timeout,
      );
      final capabilities = CapabilitySet.fromJson(
        confirm['capabilities'] ?? payload.capabilities.bits,
      );
      final hostName = confirm['host'] is String
          ? confirm['host']! as String
          : '';
      onConfirm?.call(hostName, capabilities);

      link.send(await channel.seal(PairingMessage.encodeAck()));
      await _awaitSealed(frames, channel, PairingMessage.done, timeout);

      final pairing = CompanionPairing(
        hostId: payload.hostId,
        deviceId: deviceId,
        deviceKey: Uint8List.fromList(key.bytes),
        capabilities: capabilities,
        relay: payload.relay,
        generation: kFirstSessionGeneration,
        hostName: hostName,
      );
      await pairing.save(store);
      return pairing;
    } on TimeoutException {
      throw const CompanionPairingException(
        'the desktop did not answer — is the QR code still on screen?',
      );
    } finally {
      await frames.cancel();
      if (ownsTransport) await link.close();
    }
  }

  /// Pairs from a typed code's secret alone (no payload).
  ///
  /// The pairing secret and rendezvous are HKDF-derived from [codeSecret];
  /// [relay] is this phone's own configured relay (the code carries none) and
  /// is what the stored pairing dials afterwards. The host's confirm arrives
  /// sealed under a key derived from the secret alone and carries the host id
  /// and grant; the ack/done round-trip under the id-bound device key then
  /// proves both ends derived the same key before anything is persisted.
  Future<CompanionPairing> pairWithTypedCode({
    required Uint8List codeSecret,
    required Uri relay,
    RemoteTransport? transport,
    Duration timeout = const Duration(seconds: 30),
    void Function(String hostName, CapabilitySet capabilities)? onConfirm,
  }) async {
    final secret = Uint8List.fromList(
      (await derivePairingSecret(codeSecret)).bytes,
    );
    final rendezvous = await derivePairingRendezvous(secret);
    final ownsTransport = transport == null;
    final link =
        transport ??
        RelayTransport.connect(relay: relay, rendezvous: rendezvous);
    final frames = StreamIterator<Uint8List>(link.frames);
    try {
      final confirmChannel = await SealedChannel.forDevice(
        deviceKey: await derivePairingConfirmKey(secret),
        role: ChannelRole.companion,
      );

      link.send(LinkHello(rendezvous).encode());
      link.send(
        PairHello(
          deviceId: deviceId,
          name: deviceName,
          needsHostIdentity: true,
        ).encode(),
      );

      final confirm = await _awaitSealed(
        frames,
        confirmChannel,
        PairingMessage.confirm,
        timeout,
      );
      final hostIdText = confirm['hostId'];
      if (hostIdText is! String) {
        throw const CompanionPairingException(
          'this desktop is too old for typed pairing codes — scan its QR '
          'code instead',
        );
      }
      final DeviceId hostId;
      try {
        hostId = DeviceId.parse(hostIdText);
      } on ProtocolException {
        throw const CompanionPairingException(
          'the desktop sent a malformed pairing confirmation',
        );
      }
      final capabilities = CapabilitySet.fromJson(confirm['capabilities'] ?? 0);
      final hostName = confirm['host'] is String
          ? confirm['host']! as String
          : '';
      onConfirm?.call(hostName, capabilities);

      final key = await deriveDeviceKey(
        pairingSecret: secret,
        hostId: hostId,
        deviceId: deviceId,
      );
      final channel = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.companion,
      );
      link.send(await channel.seal(PairingMessage.encodeAck()));
      await _awaitSealed(frames, channel, PairingMessage.done, timeout);

      final pairing = CompanionPairing(
        hostId: hostId,
        deviceId: deviceId,
        deviceKey: Uint8List.fromList(key.bytes),
        capabilities: capabilities,
        relay: relay,
        generation: kFirstSessionGeneration,
        hostName: hostName,
      );
      await pairing.save(store);
      return pairing;
    } on TimeoutException {
      throw const CompanionPairingException(
        'the desktop did not answer — is the pairing code still on screen, '
        'and typed exactly?',
      );
    } finally {
      await frames.cancel();
      if (ownsTransport) await link.close();
    }
  }

  /// Waits for the next sealed pairing message of [expected] type, skipping
  /// frames that are not for us (a hello echo, somebody else's noise).
  Future<Map<String, Object?>> _awaitSealed(
    StreamIterator<Uint8List> frames,
    SealedChannel channel,
    String expected,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('pairing timed out');
      final has = await frames.moveNext().timeout(left);
      if (!has) {
        throw const CompanionPairingException('the connection closed');
      }
      final SealedFrame opened;
      try {
        opened = await channel.unseal(frames.current);
      } on SealedChannelException {
        continue;
      }
      final json = PairingMessage.decode(opened.plaintext);
      if (json == null || json['t'] != expected) continue;
      return json;
    }
  }
}
