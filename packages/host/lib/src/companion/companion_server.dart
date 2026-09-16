import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../domain/session_registry.dart';

import 'companion_bindings.dart';

/// Serves the companion's own frame protocol over one link.
///
/// **The host is a peer the phone pairs with, not a machine behind somebody
/// else's desktop.** Its own pairing table lives in its own store, so the
/// ceremony a desktop runs on screen is the ceremony this runs in a terminal —
/// and the same server answers a phone on localhost, on the LAN, or through a
/// relay. That is the point of putting it here rather than in the app: one
/// pairable host, many transports, and a phone that can pair with any of them.
///
/// **SSH is therefore a transport and never the trust root.** It authenticates
/// a *Unix user* to a machine; pairing authenticates *this phone* to *this
/// host*, which is the question the api actually asks — and on localhost there
/// is no SSH in the picture at all. So [clientId] and [capabilities] come from
/// the paired-device row, exactly as they do on the desktop. Two phones must
/// never share a [clientId]: the api keys each link's staged attachment bytes
/// on it, so one would read the other's.
///
/// **Unsealed today, and only because nothing has paired yet.** The sealed
/// channel is what carries a device key, and there is no key until the pairing
/// half lands here. `SealedChannel` is itself a [RemoteTransport], so [serve]
/// sits on one without changing a line — which is the reason it takes frames
/// rather than bytes.
class CompanionServer {
  CompanionServer({
    required this.registry,
    required this.hostName,
    required this.clientId,
    CapabilitySet? capabilities,
    DateTime Function()? clock,
  }) : // Everything only while nothing can pair. Once a row exists the grant
       // comes from it, and a host that defaulted would be ignoring it.
       capabilities = capabilities ?? CapabilitySet.all,
       _now = clock ?? DateTime.now;

  final SessionRegistry registry;
  final String hostName;

  /// Which phone this link is — the paired device's id, once there is one.
  final String clientId;

  /// What that phone was granted when it paired with this host.
  final CapabilitySet capabilities;

  final DateTime Function() _now;

  /// Answers frames until [link] ends. Completes when the peer goes away; it
  /// does not close the link, because the caller owns it.
  ///
  /// A [RemoteTransport] and not a byte channel, which is the layer the desktop
  /// serves at too: `LanLink`, the relay transport and a `SealedChannel` are all
  /// one, and every one of them already frames. Taking bytes here would mean
  /// framing a second time on top of transports that had done it once.
  Future<void> serve(RemoteTransport link) async {
    var seq = 0;

    Future<bool> send(
      FrameType type, {
      String? id,
      Map<String, Object?> payload = const {},
    }) async {
      link.send(Envelope.of(type, seq: seq++, id: id, payload: payload).toBytes());
      return true;
    }

    final api = HostSessionApi(
      device: _localDevice(),
      bindings: hostCompanionBindings(registry, hostName: hostName),
      send: send,
    );

    await for (final frame in link.frames) {
      // A frame this build cannot even decode is refused rather than dropped.
      // A phone that gets no answer cannot tell a refusal from a host that has
      // stopped reading, which is precisely the failure `91a457db` was.
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

  /// The phone on the other end, as the api's own type. The key is empty and
  /// the generation zero because the link below has already used them: a
  /// `SealedChannel` proves which device is speaking before a frame gets here,
  /// so re-checking the key at this layer would be asking a question the
  /// transport has already answered.
  PairedDevice _localDevice() => PairedDevice(
    id: clientId,
    name: clientId,
    deviceKey: Uint8List(0),
    capabilities: capabilities,
    generation: 0,
    createdAt: _now(),
  );
}
