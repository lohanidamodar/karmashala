import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../domain/session_registry.dart';
import '../transport/transport.dart';
import 'companion_bindings.dart';

/// Serves the companion's own frame protocol over one byte channel.
///
/// **Not sealed, and that is the point of running it over SSH.** The desktop
/// seals because it speaks across a LAN or a relay it does not control; an SSH
/// exec channel is already authenticated and encrypted, and a second key
/// schedule inside it would add ceremony and no property. What SSH does not
/// carry is a pairing, so there is no granted capability set to enforce — the
/// login *is* the machine's own user, and [CapabilitySet.all] says so once here
/// rather than being defaulted into existence somewhere it cannot be read.
class CompanionServer {
  CompanionServer({
    required this.registry,
    required this.hostName,
    required this.clientId,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final SessionRegistry registry;
  final String hostName;

  /// Names the link in refusals and in the api's own bookkeeping. One channel
  /// is one client, so it is the channel's id rather than a paired device's.
  final String clientId;

  final DateTime Function() _now;

  /// Reads frames until [connection] ends, answering each one. Completes when
  /// the peer goes away; it does not close the connection itself, because the
  /// caller owns it (`attach` proxies stdio, a test drives a pipe).
  Future<void> serve(HostConnection connection) async {
    final framer = LengthPrefixedFramer();
    var seq = 0;

    Future<bool> send(
      FrameType type, {
      String? id,
      Map<String, Object?> payload = const {},
    }) async {
      final envelope = Envelope.of(type, seq: seq++, id: id, payload: payload);
      connection.add(LengthPrefixedFramer.encode(envelope.toBytes()));
      await connection.flush();
      return true;
    }

    final api = HostSessionApi(
      device: _localDevice(),
      bindings: hostCompanionBindings(registry, hostName: hostName),
      send: send,
    );

    await for (final chunk in connection.incoming) {
      for (final frame in framer.add(chunk)) {
        // A frame this build cannot even decode is refused rather than dropped.
        // A phone that gets no answer cannot tell a refusal from a host that
        // has stopped reading, which is precisely the failure `91a457db` was.
        try {
          await api.handleEnvelope(Envelope.fromBytes(frame));
        } on ProtocolException catch (e) {
          await send(
            FrameType.error,
            payload: {'code': ErrorCode.badRequest.wire, 'message': e.message},
          );
        }
      }
    }
  }

  /// The client on the other end of an SSH channel. It is not a paired device —
  /// nothing was paired — so the fields a pairing would have fill in as what an
  /// SSH login actually means: everything granted, nothing remembered.
  PairedDevice _localDevice() => PairedDevice(
    id: clientId,
    name: 'ssh',
    deviceKey: Uint8List(0),
    capabilities: CapabilitySet.all,
    generation: 0,
    createdAt: _now(),
  );
}
