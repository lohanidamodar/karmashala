/// The host side of one pairing attempt: the phone dials the pairing
/// rendezvous, both ends derive the device key, a sealed confirm/ack round-trip
/// proves both hold it, and only then is the device row persisted. The secret
/// is single-use and expires with [PairingPayload]'s TTL.
library;

import 'dart:async';
import 'dart:typed_data';

import '../domain/paired_device.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import 'pairing_payload.dart';
import 'pairing_wire.dart';

/// Pairing failed in a way the dialog should say out loud.
class PairingException implements Exception {
  const PairingException(this.message);

  final String message;

  @override
  String toString() => 'PairingException: $message';
}

/// One shown QR code, waiting for one phone. Attach every transport the host
/// is listening on for this rendezvous; the first phone to complete the sealed
/// round-trip wins, and the secret is then spent.
class HostPairingSession {
  HostPairingSession({
    required this.payload,
    required this.hostName,
    required this.persist,
    DateTime Function()? now,
    Duration ttl = kPairingTtl,
  }) : _now = now ?? DateTime.now,
       _deadline = (now ?? DateTime.now)().add(ttl);

  final PairingPayload payload;

  /// What the confirm message calls this desktop.
  final String hostName;

  /// Writes the proven device into the store. Called exactly once, after the
  /// sealed ack.
  final Future<void> Function(PairedDevice device) persist;

  final DateTime Function() _now;
  final DateTime _deadline;

  final Completer<PairedDevice> _done = Completer<PairedDevice>();
  final List<StreamSubscription<Uint8List>> _subscriptions = [];
  final List<RemoteTransport> _transports = [];

  /// Serialises frame handling so a hello and the ack behind it cannot
  /// interleave their async work.
  Future<void> _chain = Future<void>.value();

  SealedChannel? _channel;
  DeviceId? _candidateId;
  String? _candidateName;
  bool _spent = false;

  /// Completes with the paired device, or errors on expiry or [close].
  Future<PairedDevice> get done => _done.future;

  bool get isExpired => !_now().isBefore(_deadline);

  /// Listens for pairing frames on [transport] and answers on it.
  void attach(RemoteTransport transport) {
    if (_spent) return;
    _transports.add(transport);
    _subscriptions.add(
      transport.frames.listen((frame) {
        _chain = _chain.then((_) => _handle(transport, frame));
      }),
    );
  }

  /// Routes a frame that arrived on a link something else is reading —
  /// the LAN server hands frames over this way.
  void handleFrame(RemoteTransport transport, Uint8List frame) {
    if (!_transports.contains(transport)) _transports.add(transport);
    _chain = _chain.then((_) => _handle(transport, frame));
  }

  Future<void> _handle(RemoteTransport transport, Uint8List frame) async {
    if (_spent || _done.isCompleted) return;
    if (isExpired) {
      _fail(const PairingException('the pairing code has expired'));
      return;
    }

    // A link hello is routing, already done by whoever attached us.
    if (LinkHello.tryDecode(frame) != null) return;

    final hello = PairHello.tryDecode(frame);
    if (hello != null) {
      // Single-use: the first phone to say hello claims the secret. A repeat
      // from the same phone (a redial) restarts the confirm; any other phone
      // is ignored.
      if (_candidateId != null && _candidateId != hello.deviceId) return;
      _candidateId = hello.deviceId;
      _candidateName = hello.name;
      final key = await deriveDeviceKey(
        pairingSecret: payload.secret,
        hostId: payload.hostId,
        deviceId: hello.deviceId,
      );
      _channel = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.host,
      );
      final confirm = PairingMessage.encodeConfirm(
        hostName: hostName,
        capabilities: payload.capabilities,
        hostId: hello.needsHostIdentity ? payload.hostId : null,
      );
      if (hello.needsHostIdentity) {
        // Typed-code phone: it cannot derive the id-bound device key yet, so
        // the confirm rides a key derived from the secret alone and carries
        // the host id, which the ack/done round-trip then proves.
        final confirmChannel = await SealedChannel.forDevice(
          deviceKey: await derivePairingConfirmKey(payload.secret),
          role: ChannelRole.host,
        );
        transport.send(await confirmChannel.seal(confirm));
      } else {
        transport.send(await _channel!.seal(confirm));
      }
      return;
    }

    // Everything else must be sealed. Anything that fails to open is not the
    // phone we are pairing with, and says nothing worth crashing over.
    final channel = _channel;
    if (channel == null) return;
    final SealedFrame opened;
    try {
      opened = await channel.unseal(frame);
    } on SealedChannelException {
      return;
    }
    if (PairingMessage.typeOf(opened.plaintext) != PairingMessage.ack) return;

    // The phone proved it derived the same key. Persist, tell it, finish.
    final device = PairedDevice(
      id: _candidateId!.value,
      name: _candidateName!,
      deviceKey: Uint8List.fromList(
        (await deriveDeviceKey(
          pairingSecret: payload.secret,
          hostId: payload.hostId,
          deviceId: _candidateId!,
        )).bytes,
      ),
      capabilities: payload.capabilities,
      generation: kFirstSessionGeneration,
      createdAt: _now().toUtc(),
    );
    await persist(device);
    transport.send(await channel.seal(PairingMessage.encodeDone()));
    _spent = true;
    if (!_done.isCompleted) _done.complete(device);
  }

  void _fail(Object error) {
    if (_done.isCompleted) return;
    _done.completeError(error);
    // The dialog may not be awaiting yet; a late listener still gets the
    // error, but an unheard one must not surface as an unhandled zone error.
    _done.future.ignore();
  }

  /// Stops listening. Does not close the transports — the caller owns those.
  Future<void> close() async {
    _spent = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _fail(const PairingException('pairing was cancelled'));
    // A completer nobody awaited yet must not surface as unhandled.
    _done.future.ignore();
  }
}
