import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

import '../domain/session_registry.dart';
import 'device_links.dart';

/// Accepts companion links and gives each one to whoever it is for.
///
/// **A link says who it is before anything is unsealed.** The first frame is a
/// [LinkHello] in the clear carrying a rendezvous id, which is derived from a
/// device key — so it names the device without naming it, and a host with no
/// matching route learns nothing and answers nothing. Everything after it is
/// sealed with that device's key.
///
/// The same listener serves pairing: a pairing window has a rendezvous of its
/// own, so a phone that has never paired arrives on the same port and is told
/// apart by which rendezvous it asked for.
class CompanionListener {
  CompanionListener({
    required SessionRegistry registry,
    required String hostName,
    required List<PairedDevice> Function() devices,
    void Function(String deviceId, int generation)? onGeneration,
    DeviceLinks? links,
    this.onLog,
  }) : links =
           links ??
           DeviceLinks(
             registry: registry,
             hostName: hostName,
             devices: devices,
             onGeneration: onGeneration,
             onLog: onLog,
           );

  /// Who a rendezvous belongs to and how it is served. Shared with the relay
  /// listener, so a phone is recognised by one rule however it arrived.
  final DeviceLinks links;

  final void Function(String message)? onLog;

  /// How long a link has to say who it is. A dialer that opens a socket and
  /// then says nothing costs a connection for as long as it likes otherwise,
  /// and on a public address that is the cheapest thing an outsider can do.
  /// The real phone sends its hello immediately.
  static const Duration helloDeadline = Duration(seconds: 10);

  LanTransportServer? _server;
  StreamSubscription<LanLink>? _links;

  /// The pairing window, while one is open. A host with none refuses every
  /// unknown rendezvous, which is what makes an unpaired dialer cheap.
  HostPairingSession? _pairing;

  int get port => _server?.port ?? 0;

  /// Binds the listener. [address] is `0.0.0.0` so a box answers on whichever
  /// interface the phone found it by; which address that is, the person
  /// pairing already knows — a host cannot read its own public address and does
  /// not try.
  Future<void> start({
    Object address = '0.0.0.0',
    int port = kHostCompanionPort,
  }) async {
    if (_server != null) return;
    final server = await LanTransportServer.bind(
      address: address,
      port: port,
      onLog: onLog,
    );
    _server = server;
    _links = server.connections.listen(_accept);
    onLog?.call(
      'companion listener on ${server.address.address}:${server.port}',
    );
  }

  /// Opens the door for one phone. The caller shows the code; this routes the
  /// link when it arrives.
  void acceptPairing(HostPairingSession session) => _pairing = session;

  /// Shuts the door [session] opened, unless a newer window has replaced it.
  void endPairing(HostPairingSession session) {
    if (identical(_pairing, session)) _pairing = null;
  }

  void _accept(LanLink link) {
    // Nobody owns this link until the hello arrives, so the first frame routes
    // it and every frame after goes wherever that decided.
    void Function(Uint8List frame)? route;
    void Function()? onGone;
    // Resolving is async — a rendezvous is derived per device — and a phone
    // does not wait to be recognised before it speaks. Frames that arrive in
    // that window are held, not read as a second hello and not dropped.
    var resolving = false;
    final waiting = <Uint8List>[];
    late final StreamSubscription<Uint8List> frames;

    var owned = false;
    void refuse(String why) {
      onLog?.call(why);
      frames.cancel();
      link.close();
    }

    // A link that never says who it is is closed rather than held. `maxLinks`
    // caps how many an outsider can hold at once; this caps how long, which is
    // the other half and the one a public address makes matter.
    final deadline = Timer(helloDeadline, () {
      if (owned) return;
      refuse('a link said nothing for ${helloDeadline.inSeconds}s');
    });

    frames = link.frames.listen(
      (frame) {
        final decided = route;
        if (decided != null) {
          decided(frame);
          return;
        }
        if (resolving) {
          waiting.add(frame);
          return;
        }
        final hello = LinkHello.tryDecode(frame);
        if (hello == null) {
          // Not even a hello. Nothing is owed to a dialer that opened with
          // something else, and holding the socket is what it would cost us.
          deadline.cancel();
          refuse('a link opened with something other than a hello');
          return;
        }
        resolving = true;
        _routeHello(link, hello).then((routed) {
          deadline.cancel();
          if (routed == null) {
            refuse('a link asked for a rendezvous nobody here answers');
            return;
          }
          final forward = routed.deliver;
          owned = true;
          route = forward;
          onGone = routed.gone;
          for (final held in waiting) {
            forward(held);
          }
          waiting.clear();
        });
      },
      onDone: () {
        deadline.cancel();
        // The socket closing is the only news a served link gets that the phone
        // has gone, and without it the server behind it waits for ever.
        onGone?.call();
      },
    );
  }

  /// Who this rendezvous belongs to, or null for nobody. The hello itself is
  /// delivered here when its owner wants it — a pairing session reads it, and a
  /// sealed link must never be handed a frame that was never sealed.
  Future<({void Function(Uint8List frame) deliver, void Function()? gone})?>
  _routeHello(LanLink link, LinkHello hello) async {
    final wanted = hello.rendezvous.value;

    final pairing = _pairing;
    if (pairing != null && pairing.payload.rendezvous.value == wanted) {
      pairing.handleFrame(link, hello.encode());
      return (
        deliver: (Uint8List frame) => pairing.handleFrame(link, frame),
        gone: null,
      );
    }

    final match = await links.match(wanted);
    if (match == null) return null;
    final served = links.serve(link, match);
    if (served == null) return null;
    return (deliver: served.deliver, gone: served.end);
  }

  Future<void> stop() async {
    await _links?.cancel();
    _links = null;
    await _server?.close();
    _server = null;
    _pairing = null;
  }
}
