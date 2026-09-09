/// Same-network discovery for the direct path.
///
/// The design asks for mDNS (`_karmashala._tcp`). `package:multicast_dns` —
/// the Flutter team's — is a **client only**: `MDnsClient` queries and caches,
/// and there is no responder in it, so the desktop host has nothing to
/// advertise with. The alternatives that can advertise (`bonsoir`, `nsd`) are
/// Flutter plugins with per-platform native code, which would put a plugin in
/// the way of a headless unit test and in the way of the pure-Dart host.
///
/// So this is a minimal UDP multicast beacon instead: the host repeats a small
/// datagram, the companion listens for it. The service name travels in the
/// payload, so a real mDNS responder can take over later without changing
/// anything above.
///
/// The beacon carries **no identity**: a per-boot random tag, never a device id
/// and never a key, so anyone sniffing the LAN learns that a Karmashala host
/// is here and nothing about who is paired with it. The sealed handshake is
/// what proves a host is the right one; discovery is only a hint about where to
/// dial.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The service name, kept from the design so a future mDNS responder matches.
const String kLanServiceName = '_karmashala._tcp';

/// The beacon's multicast group and port. Not 224.0.0.251:5353 — that is mDNS,
/// and putting non-mDNS datagrams there would confuse every responder on the
/// network.
final InternetAddress kLanBeaconGroup = InternetAddress('239.255.42.99');
const int kLanBeaconPort = 47654;

/// How often the host repeats itself.
const Duration kLanBeaconInterval = Duration(seconds: 2);

/// How long a discovered host stays in the list without being heard from —
/// five [kLanBeaconInterval]s, so the patience is a count of missed beacons
/// rather than a stopwatch reading.
const Duration kLanHostTimeout = Duration(seconds: 10);

/// Longest datagram the beacon will parse, so a stray packet cannot be costly.
const int kMaxBeaconBytes = 512;

/// What the host says about itself on the LAN.
class LanAdvert {
  const LanAdvert({
    required this.port,
    required this.tag,
    this.service = kLanServiceName,
    this.version = 1,
  });

  /// The TCP port the host's [LanTransportServer] is listening on.
  final int port;

  /// A random per-boot label, used only to tell two hosts apart. Never a device
  /// id: the LAN must not learn who is paired.
  final String tag;

  final String service;
  final int version;

  /// A fresh tag. 8 bytes is plenty to tell hosts apart and useless for
  /// tracking, since it changes every time the app starts.
  static String newTag([Random? random]) {
    final rng = random ?? Random.secure();
    return List<int>.generate(
      8,
      (_) => rng.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'s': service, 'v': version, 'port': port, 'tag': tag}),
    ),
  );

  /// Parses a datagram, or returns null when it is not one of ours.
  static LanAdvert? tryDecode(List<int> datagram) {
    if (datagram.isEmpty || datagram.length > kMaxBeaconBytes) return null;
    try {
      final json = jsonDecode(utf8.decode(datagram));
      if (json is! Map<String, Object?>) return null;
      final port = json['port'];
      final tag = json['tag'];
      final version = json['v'];
      if (json['s'] != kLanServiceName) return null;
      if (port is! int || port < 1 || port > 65535) return null;
      if (tag is! String || tag.isEmpty || tag.length > 64) return null;
      if (version is! int) return null;
      return LanAdvert(port: port, tag: tag, version: version);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'LanAdvert($service v$version port=$port tag=$tag)';
}

/// A host heard on the LAN.
class DiscoveredHost {
  const DiscoveredHost({
    required this.address,
    required this.advert,
    required this.seenAt,
  });

  final InternetAddress address;
  final LanAdvert advert;
  final DateTime seenAt;

  int get port => advert.port;
  String get tag => advert.tag;

  @override
  String toString() => 'DiscoveredHost(${address.address}:$port ${advert.tag})';
}

/// The host side: repeats an advert on the multicast group.
class LanBeacon {
  LanBeacon._(this._socket, this._timer);

  /// Starts advertising [port] under [tag] until [stop].
  ///
  /// [bindAddress] is which interface the adverts leave by; the default —
  /// every interface — is what the desktop wants. Tests pass the loopback
  /// address so the suite never sprays datagrams onto the machine's real
  /// network, and so it keeps working where the OS withholds permission to use
  /// one (macOS 15+ denies multicast outright until the user grants Local
  /// Network access, which no headless test run can do).
  static Future<LanBeacon> advertise({
    required int port,
    required String tag,
    Duration interval = kLanBeaconInterval,
    InternetAddress? group,
    int beaconPort = kLanBeaconPort,
    InternetAddress? bindAddress,
  }) async {
    final target = group ?? kLanBeaconGroup;
    final socket = await RawDatagramSocket.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
    socket.multicastLoopback = true;
    if (bindAddress != null) _sendMulticastFrom(socket, bindAddress);
    final payload = LanAdvert(port: port, tag: tag).encode();
    void announce() {
      try {
        socket.send(payload, target, beaconPort);
      } on SocketException {
        // A network that just went away; the next tick tries again.
      }
    }

    announce();
    return LanBeacon._(socket, Timer.periodic(interval, (_) => announce()));
  }

  final RawDatagramSocket _socket;
  final Timer _timer;

  void stop() {
    _timer.cancel();
    _socket.close();
  }
}

/// The companion side: listens for adverts and keeps a live list of hosts.
class LanDiscovery {
  LanDiscovery._(this._socket, this._timeout, this._now) {
    _socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram == null) return;
      final advert = LanAdvert.tryDecode(datagram.data);
      if (advert == null) return;
      final host = DiscoveredHost(
        address: datagram.address,
        advert: advert,
        seenAt: _now(),
      );
      _hosts['${datagram.address.address}:${advert.port}'] = host;
      if (!_found.isClosed) _found.add(host);
    });
  }

  /// Joins the beacon group and starts listening.
  ///
  /// Android needs a multicast lock held for this to receive anything; that is
  /// the companion loop's job, and is why this can look silent on a phone while
  /// working on desktop.
  ///
  /// The group is joined on **every** interface rather than on the default one.
  /// A bare `joinMulticast(group)` leaves the choice to the OS, which picks one
  /// — and the one it picks is routinely not the one the host is advertising
  /// on. Every desktop this runs on is multi-homed: Windows carries the WSL and
  /// Hyper-V switches, macOS carries `lo0`, `awdl0` and `llw0` beside the real
  /// adapter, and a VPN adds another. Joining everywhere is what makes the
  /// direct path find a host that is right there.
  ///
  /// A refusal on one interface is skipped rather than fatal: `awdl0` and
  /// friends come and go, and one that will not take the join must not cost the
  /// discovery the interfaces that would have.
  ///
  /// [now] is the clock both halves of the freshness judgement read — when a
  /// host was heard and whether it has since gone quiet. It exists so a caller
  /// can count missed beacons instead of waiting for them, and so a scout that
  /// was given a clock has only the one. The default is the wall clock.
  static Future<LanDiscovery> start({
    InternetAddress? group,
    int beaconPort = kLanBeaconPort,
    Duration timeout = kLanHostTimeout,
    DateTime Function()? now,
  }) async {
    final target = group ?? kLanBeaconGroup;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      beaconPort,
      reuseAddress: true,
    );
    var joined = 0;
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: true,
    )) {
      try {
        socket.joinMulticast(target, interface);
        joined++;
      } on OSError {
        // This interface will not carry the group; others may.
      } on SocketException {
        // Same.
      }
    }
    // Nothing enumerable to join on — fall back to letting the OS choose, which
    // is still better than a socket that has joined nothing at all.
    if (joined == 0) socket.joinMulticast(target);
    return LanDiscovery._(socket, timeout, now ?? DateTime.now);
  }

  final RawDatagramSocket _socket;
  final Duration _timeout;
  final DateTime Function() _now;
  final Map<String, DiscoveredHost> _hosts = <String, DiscoveredHost>{};
  final StreamController<DiscoveredHost> _found =
      StreamController<DiscoveredHost>.broadcast();

  /// Every advert as it arrives, repeats included — a caller that wants a list
  /// reads [hosts] instead.
  Stream<DiscoveredHost> get adverts => _found.stream;

  /// Hosts heard from recently enough to still be worth dialling — those
  /// whose last advert is no more than [kLanHostTimeout], five beacons, old.
  List<DiscoveredHost> get hosts {
    final cutoff = _now().subtract(_timeout);
    _hosts.removeWhere((_, host) => host.seenAt.isBefore(cutoff));
    return List<DiscoveredHost>.unmodifiable(_hosts.values);
  }

  Future<void> stop() async {
    _socket.close();
    await _found.close();
  }
}

/// Pins [socket]'s outgoing multicast to the interface holding [address].
///
/// Binding a datagram socket to an address sets where its packets say they are
/// *from*; it does not decide which interface they leave by. That is chosen
/// from the routing table, and for a multicast group the matching route is the
/// blanket `224.0.0.0/4` one — which on this machine points at the Wi-Fi
/// adapter no matter what the socket is bound to. The interface is also
/// resolved on the socket's **first send** and cached, so a beacon that starts
/// advertising before anything has joined the group keeps using that answer for
/// its whole life.
///
/// That combination is what made a beacon bound to loopback undiscoverable: it
/// sent its first datagram out of the Wi-Fi adapter, and every datagram after
/// it, while the listener that joined a moment later was waiting on `lo0`.
/// Reversing the order hid the bug — which is why it looked like a race.
///
/// `IP_MULTICAST_IF` says it outright. There is no `dart:io` accessor for it,
/// so it goes through [RawSocketOption] with the platform's own option number,
/// and a platform that refuses is left with the routing table it had.
void _sendMulticastFrom(RawDatagramSocket socket, InternetAddress address) {
  // IPPROTO_IP is 0 everywhere. IP_MULTICAST_IF is 9 on the BSDs (macOS
  // included) and on Winsock, and 32 on Linux.
  const level = 0;
  final option = Platform.isLinux ? 32 : 9;
  try {
    socket.setRawOption(
      RawSocketOption(level, option, address.rawAddress),
    );
  } on OSError {
    // Left to the routing table, which is what it did before this existed.
  } on SocketException {
    // Same.
  }
}
