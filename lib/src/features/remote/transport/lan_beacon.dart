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

/// How long a discovered host stays in the list without being heard from.
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
  static Future<LanBeacon> advertise({
    required int port,
    required String tag,
    Duration interval = kLanBeaconInterval,
    InternetAddress? group,
    int beaconPort = kLanBeaconPort,
  }) async {
    final target = group ?? kLanBeaconGroup;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.multicastLoopback = true;
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
  LanDiscovery._(this._socket, this._timeout) {
    _socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram == null) return;
      final advert = LanAdvert.tryDecode(datagram.data);
      if (advert == null) return;
      final host = DiscoveredHost(
        address: datagram.address,
        advert: advert,
        seenAt: DateTime.now(),
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
  static Future<LanDiscovery> start({
    InternetAddress? group,
    int beaconPort = kLanBeaconPort,
    Duration timeout = kLanHostTimeout,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      beaconPort,
      reuseAddress: true,
    );
    socket.joinMulticast(group ?? kLanBeaconGroup);
    return LanDiscovery._(socket, timeout);
  }

  final RawDatagramSocket _socket;
  final Duration _timeout;
  final Map<String, DiscoveredHost> _hosts = <String, DiscoveredHost>{};
  final StreamController<DiscoveredHost> _found =
      StreamController<DiscoveredHost>.broadcast();

  /// Every advert as it arrives, repeats included — a caller that wants a list
  /// reads [hosts] instead.
  Stream<DiscoveredHost> get adverts => _found.stream;

  /// Hosts heard from recently enough to still be worth dialling.
  List<DiscoveredHost> get hosts {
    final cutoff = DateTime.now().subtract(_timeout);
    _hosts.removeWhere((_, host) => host.seenAt.isBefore(cutoff));
    return List<DiscoveredHost>.unmodifiable(_hosts.values);
  }

  Future<void> stop() async {
    _socket.close();
    await _found.close();
  }
}
