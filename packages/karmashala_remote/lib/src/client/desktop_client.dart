/// A desktop app as the client of a server on another machine (slice 5e):
/// the phone's pairing record and sealed channel, switched to the host
/// protocol with `host.attach`, over the server's LAN listener or a relay.
library;

import 'dart:async';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:karmashala_host_protocol/host_access.dart' show RemoteChannel;

import '../domain/known_relays.dart' show KnownRelays, sameRelay;
import '../domain/remote_payloads.dart' show RemoteHostStatus;
import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/lan_beacon.dart' show DiscoveredHost, LanAdvert;
import '../transport/lan_transport.dart';
import '../transport/link_liveness.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import '../transport/sealed_host_link.dart';
import 'companion_store.dart';
import 'lan_path.dart' show LanDialerFn, LanPathScout;
import 'relay_candidates.dart';
import 'relay_dial.dart';
import 'route_pin.dart';

part 'desktop_client/link_keeper.dart';
part 'desktop_client/server_dialer.dart';

/// Why a desktop could not reach its server; [message] is safe to show.
class DesktopConnectException implements Exception {
  const DesktopConnectException(
    this.message, {
    this.refused = false,
    this.granted,
  });

  final String message;

  /// The server answered and said no (the pairing grants no desktop): no
  /// other route or generation will say otherwise.
  final bool refused;

  /// On a refused attach, what the server's `host.status` said this pairing
  /// holds (the stored record's grants when an older server said nothing).
  final CapabilitySet? granted;

  @override
  String toString() => message;
}

/// The server moved this pairing to [to] and the move was saved and
/// acknowledged; this socket was let go, unattached, so the dial meets the
/// server there instead.
class DesktopRelayMoved implements Exception {
  const DesktopRelayMoved(this.to);

  final Uri to;

  @override
  String toString() => 'moved to the relay at ${to.host}';
}

/// How a switched link comes back after its socket drops (Stage 0 step 17),
/// instead of ending: the server keeps it for [grace] (`link.resume`, step
/// 16), and the link is resumed over whichever of [routes] answers first.
class DesktopLinkResume {
  const DesktopLinkResume({
    required this.offered,
    required this.routes,
    this.hostName = 'the server',
    this.grace = kHostLinkResumeGrace,
    this.onLog,
    this.onHeld,
    this.promoteOffered,
    this.keepaliveOffered,
    this.lanRoutes,
    this.lanChances,
    this.proofs,
  });

  /// Fires when the link may be on a socket that is gone — the app came back
  /// to the front, or the network changed. A live link pings and is taken
  /// for dropped if nothing answers within [kDesktopProofWindow]; a held one
  /// tries its routes at once.
  final Stream<void>? proofs;

  /// Hears true when the link is held for a resume, and false once it is
  /// back or has ended — for a "Reconnecting…" banner. A promotion is not a
  /// hold: it never says anything here.
  final void Function(bool held)? onHeld;

  /// Asked before each promotion (Stage 0 step 18): whether the server
  /// announced `link.promote` — it takes a resume onto a second socket while
  /// the first still carries the link. Null or false: a link on a relay
  /// stays there, as before.
  final bool Function()? promoteOffered;

  /// Asked on each idle tick: whether the server announced `link.keepalive`
  /// — it answers an empty frame. Null or false: no pings, and silence is
  /// never taken for a dead socket.
  final bool Function()? keepaliveOffered;

  /// The routes a link on a relay may be promoted to, at its generation,
  /// best first: never a relay, and none under a relay pin.
  final Future<List<DesktopResumeRoute>> Function(int generation)? lanRoutes;

  /// Fires when a promotion may have become possible — a beacon sighting
  /// not in cooldown. The keeper also looks every
  /// [kDesktopPromotionRecheck], for the announced LAN address.
  final Stream<void>? lanChances;

  /// Asked at the drop: whether the server announced `link.resume` in its
  /// welcome. False — an older server, or a link that never said hello —
  /// ends the link at once, as before a resume existed.
  final bool Function() offered;

  /// The routes to try for the link's generation, best first; asked afresh
  /// for each pass, so a sighting or relay learned meanwhile is in it.
  final Future<List<DesktopResumeRoute>> Function(int generation) routes;

  final String hostName;

  /// The heal timer: the one place that gives up. When it fires the link
  /// ends, and the owners above it redial as they always did.
  final Duration grace;

  /// One line when a link is suspended, and one per outcome.
  final void Function(String message)? onLog;
}

/// One way back to the server for a resume.
class DesktopResumeRoute {
  const DesktopResumeRoute({
    required this.path,
    required this.label,
    required this.timeout,
    required this.open,
    this.noted,
    this.relayHost,
    this.address,
  });

  /// `direct`, `lan`, `relay`… for the log.
  final String path;

  /// For a relay route, the relay's host: a link resumed here is on a relay,
  /// and may later be promoted off it.
  final String? relayHost;

  /// For a direct or LAN route, the address dialled: never a promotion's
  /// target when it is the very relay the link is on.
  final String? address;

  /// Where, safe to log.
  final String label;

  /// How long connecting and the resume's answer may take together.
  final Duration timeout;

  final Future<RemoteTransport> Function() open;

  /// Hears whether the server answered here, for route health.
  final void Function(bool answered)? noted;
}

/// The heal loop's waits between passes over every route.
const List<Duration> kDesktopResumeDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
];

/// How long a link asked to prove itself waits for any frame after its ping
/// before its socket is taken for dropped: a relay round trip on a cellular
/// network, with slack.
const Duration kDesktopProofWindow = Duration(seconds: 4);

/// How often a link on a relay looks for a LAN route without a beacon to
/// prompt it — the server's announced LAN address, or the typed one.
const Duration kDesktopPromotionRecheck = Duration(seconds: 60);

/// How long going back to the relay after a promotion that did not land may
/// take: a resume over a socket that is already up.
const Duration kDesktopRollbackTimeout = Duration(seconds: 6);

/// A promotion that did not land waits this long before the next, doubling
/// each time up to [kDesktopPromotionHoldOffCap]; one that lands resets it.
/// Like the phone's widening hold-off (`kLanPromotionHoldOffCap`), in time
/// rather than beacons, since the recheck is a timer too.
const Duration kDesktopPromotionHoldOff = Duration(seconds: 30);
const Duration kDesktopPromotionHoldOffCap = Duration(minutes: 16);

/// Opens one sealed host link over [transport] at [generation]: the link
/// hello, the server's `host.status`, then `host.attach`. The transport is
/// closed with the link. The link's `capabilities` are what that status
/// granted, as of this link only.
///
/// A transport that drops ends the link — unless [resume] is given and the
/// server offers `link.resume`: then the link is held (writes wait in its
/// retain window), and a heal loop resumes it over [DesktopLinkResume.routes]
/// within the grace. Whoever reads the link sees a stall, not an end. On a
/// refusal, the grace running out or a server that offers no resume, the
/// link ends as it always did.
///
/// [onHostStatus] hears the server's `host.status` — where it can be met
/// (relays, LAN address) — for the dialer to fold into the saved record.
///
/// [relayHost] names the relay [transport] reaches the server through, when
/// it does: such a link is moved onto a LAN route with a resume, before the
/// relay is let go, when [DesktopLinkResume.lanRoutes] finds one that answers
/// and the server offers `link.promote` (Stage 0 step 18). With
/// [DesktopLinkResume.keepaliveOffered], an idle link pings, and one silent
/// past [kLinkDeadAfter] is treated as dropped — a half-open socket.
///
/// With [onRelayMove], the hello says this end knows `link.relay.move`: a move
/// the server asks for is handed to it to save, then acknowledged before the
/// attach. When [hopOnMove] then answers true the socket is let go and
/// [DesktopRelayMoved] thrown, so the dial goes to the new relay.
Future<SealedHostLink> connectDesktopLink({
  required CompanionPairing pairing,
  required RemoteTransport transport,
  required int generation,
  Duration timeout = const Duration(seconds: 8),
  void Function(RemoteHostStatus status)? onHostStatus,
  DesktopLinkResume? resume,
  String? relayHost,
  Future<void> Function(Uri to)? onRelayMove,
  bool Function(Uri to)? hopOnMove,
}) async {
  final key = SecretKeyData(pairing.deviceKey);
  final channel = await SealedChannel.forDevice(
    deviceKey: key,
    role: ChannelRole.companion,
    generation: generation,
  );
  // An older server's status carries no grants: the pairing's stand in.
  var granted = pairing.capabilities;
  final greeted = Completer<void>();
  final attached = Completer<void>();
  final rendezvous = await rendezvousFor(key, generation);
  // A move saved and acknowledged — its ack sealed ahead of the attach.
  Future<Uri?>? moving;
  late final _DesktopLinkKeeper keeper;
  keeper = _DesktopLinkKeeper(
    channel: channel,
    rendezvous: rendezvous,
    generation: generation,
    resume: resume,
    relayHost: relayHost,
    onEnvelope: (envelope, opened) {
      switch (envelope.knownType) {
        case FrameType.linkRelayMove
            when !greeted.isCompleted && onRelayMove != null && moving == null:
          moving = _saveRelayMove(envelope, onRelayMove, channel, transport);
        case FrameType.hostStatus when !greeted.isCompleted:
          try {
            final caps = RemoteHostStatus.fromJson(
              envelope.payload,
            ).capabilities;
            if (caps != null) granted = caps;
          } on Object {
            // A status this build cannot read still greets.
          }
          _hearHostStatus(envelope.payload, onHostStatus);
          greeted.complete();
        case FrameType.result when envelope.id == _attachId:
          keeper.link = SealedHostLink(
            channel: channel,
            sendSealed: keeper.sendSealed,
            nextReceiveSequence: opened.sequence + 1,
            capabilities: granted,
            // Kept for a resume only where one can be asked for.
            retainForResume: resume != null,
          );
          if (!attached.isCompleted) attached.complete();
        case FrameType.error when envelope.id == _attachId:
          final message = envelope.payload['message'];
          if (!attached.isCompleted) {
            attached.completeError(
              DesktopConnectException(
                message is String ? message : 'the server refused',
                refused: true,
                granted: granted,
              ),
            );
          }
        default:
          break;
      }
    },
  );
  keeper.adopt(transport);

  Future<SealedHostLink> give(Object error) async {
    await keeper.release();
    throw error;
  }

  try {
    transport.send(
      LinkHello(
        rendezvous,
        features: onRelayMove == null ? const {} : {kLinkFeatureRelayMove},
      ).encode(),
    );
    await greeted.future.timeout(timeout);
    final moved = await moving?.timeout(timeout);
    if (moved != null && (hopOnMove?.call(moved) ?? false)) {
      return await give(DesktopRelayMoved(moved));
    }
    final envelope = Envelope.of(
      FrameType.hostAttach,
      seq: channel.nextSendSequence,
      id: _attachId,
    );
    transport.send(await channel.seal(envelope.toBytes()));
    await attached.future.timeout(timeout);
  } on TimeoutException {
    return give(
      DesktopConnectException(
        keeper.everConnected
            ? 'the server did not answer there'
            : 'nothing could be reached there',
      ),
    );
  } on DesktopConnectException catch (error) {
    return give(error);
  } on TransportException catch (error) {
    return give(DesktopConnectException(error.message));
  }
  final opened = keeper.link!;
  unawaited(opened.done.then((_) => keeper.release()));
  keeper.started();
  return opened;
}

/// Saves the move a `link.relay.move` asks for, then acknowledges it. Null
/// when the frame names no usable relay or the save failed: then nothing is
/// acknowledged and the host keeps the pairing where it was.
Future<Uri?> _saveRelayMove(
  Envelope envelope,
  Future<void> Function(Uri to) save,
  SealedChannel channel,
  RemoteTransport transport,
) async {
  final text = envelope.payload['to'];
  final to = text is String ? Uri.tryParse(text) : null;
  if (to == null || !to.hasScheme || to.host.isEmpty) return null;
  try {
    await save(to);
  } on Object {
    return null;
  }
  // No await between reading the sequence and sealing: the two must agree.
  final ack = Envelope.of(
    FrameType.linkRelayMoved,
    seq: channel.nextSendSequence,
    id: envelope.id,
    payload: {'to': text},
  );
  transport.send(await channel.seal(ack.toBytes()));
  return to;
}

/// A sealed host link as the byte channel a host-protocol link runs over.
class SealedHostChannel implements RemoteChannel {
  SealedHostChannel(this.link);

  final SealedHostLink link;

  @override
  Stream<Uint8List> get stdout => link.incoming;

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List bytes) => link.add(bytes);

  @override
  Future<int> get exitCode => link.done.then((_) => 0);

  @override
  Future<void> close() async => link.close('the client hung up');
}
