import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

import '../domain/session_registry.dart';
import 'companion_port_number.dart';
import 'companion_server.dart';
import 'sealed_link.dart';

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
    required this.registry,
    required this.hostName,
    required this.devices,
    this.onLog,
  });

  final SessionRegistry registry;
  final String hostName;

  /// Every phone this host has paired with. Read at accept time rather than
  /// captured, so a pairing that happens while this is listening is routable on
  /// the next link without a restart.
  final List<PairedDevice> Function() devices;

  final void Function(String message)? onLog;

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
    onLog?.call('companion listener on ${server.address.address}:${server.port}');
  }

  /// Opens the door for one phone. The caller shows the code; this routes the
  /// link when it arrives.
  void acceptPairing(HostPairingSession session) => _pairing = session;

  void _accept(LanLink link) {
    // Nobody owns this link until the hello arrives, so the first frame routes
    // it and every frame after goes wherever that decided.
    void Function(Uint8List frame)? route;
    // Resolving is async — a rendezvous is derived per device — and a phone
    // does not wait to be recognised before it speaks. Frames that arrive in
    // that window are held, not read as a second hello and not dropped.
    var resolving = false;
    final waiting = <Uint8List>[];
    late final StreamSubscription<Uint8List> frames;

    void refuse(String why) {
      onLog?.call(why);
      frames.cancel();
      link.close();
    }

    frames = link.frames.listen((frame) {
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
        refuse('a link opened with something other than a hello');
        return;
      }
      resolving = true;
      _routeHello(link, hello).then((forward) {
        if (forward == null) {
          refuse('a link asked for a rendezvous nobody here answers');
          return;
        }
        route = forward;
        for (final held in waiting) {
          forward(held);
        }
        waiting.clear();
      });
    });
  }

  /// Who this rendezvous belongs to, or null for nobody. The hello itself is
  /// delivered here when its owner wants it — a pairing session reads it, and a
  /// sealed link must never be handed a frame that was never sealed.
  Future<void Function(Uint8List frame)?> _routeHello(
    LanLink link,
    LinkHello hello,
  ) async {
    final wanted = hello.rendezvous.value;

    final pairing = _pairing;
    if (pairing != null && pairing.payload.rendezvous.value == wanted) {
      pairing.handleFrame(link, hello.encode());
      return (frame) => pairing.handleFrame(link, frame);
    }

    for (final device in devices()) {
      if (device.deviceKey.isEmpty) continue;
      final key = SecretKeyData(device.deviceKey);
      final rendezvous = await rendezvousFor(key, device.generation);
      if (rendezvous.value != wanted) continue;
      return _serveDevice(link, device, key);
    }

    return null;
  }

  /// Serves one paired phone: its own sealed channel, its own grant, and the
  /// sessions this machine owns.
  void Function(Uint8List frame) _serveDevice(
    LanLink link,
    PairedDevice device,
    SecretKeyData key,
  ) {
    final sealed = _PendingLink(link);
    unawaited(() async {
      final channel = await SealedChannel.forDevice(
        deviceKey: key,
        role: ChannelRole.host,
        generation: device.generation,
      );
      final plain = SealedLink(sealed, channel, onLog: onLog);
      await CompanionServer(
        registry: registry,
        hostName: hostName,
        clientId: device.id,
        capabilities: device.capabilities,
      ).serve(plain);
    }());
    return sealed.deliver;
  }

  Future<void> stop() async {
    await _links?.cancel();
    _links = null;
    await _server?.close();
    _server = null;
    _pairing = null;
  }
}

/// The accepted link, re-exposed as a transport the sealed layer can read.
///
/// The hello has already been taken off the wire by the time anybody decides
/// who the link is for, so frames arrive through [deliver] rather than by
/// listening again — a second `listen` on a single-subscription stream is an
/// error, and re-listening would lose the frames that arrived while the device
/// was being resolved.
class _PendingLink implements RemoteTransport {
  _PendingLink(this._link);

  final LanLink _link;
  final _frames = StreamController<Uint8List>();

  void deliver(Uint8List frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(List<int> frame) => _link.send(frame);

  @override
  Stream<TransportState> get states => _link.states;

  @override
  TransportState get state => _link.state;

  @override
  bool get isConnected => _link.isConnected;

  @override
  Future<void> close() async {
    if (!_frames.isClosed) await _frames.close();
    await _link.close();
  }
}
