/// The LAN relay the server hosts (`companion.localRelay` in `server.json`):
/// the relay package's [RelayServer] in the server's own process, so phones
/// paired through "this computer's relay" reach the machine whether or not a
/// desktop app runs (slice 5c follow-up; until then it lived in the app and
/// closed with it). A bad bind becomes [LocalRelayStatus], never a throw.
library;

import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart'
    show kDefaultRelayPort;

/// The port the local relay binds unless the config moves it: the relay's
/// own default (its contract, `karmashala_relay_protocol`), which phones paired
/// before the relay moved into the server still dial.
const int kDefaultLocalRelayPort = kDefaultRelayPort;

/// How long the local relay lets a socket wait alone at a rendezvous. Zero —
/// never — because every lone socket is one of this server's own listeners,
/// waiting (correctly) for a phone that may be away for hours.
const Duration kLocalRelayLoneTimeout = Duration.zero;

/// The scoped inbound firewall rule the relay tries to add on Windows.
const String kFirewallRuleName = 'Karmashala local relay';

/// The inbound rule the installer writes, which the server cannot write
/// without elevation. Program-scoped and `LocalPort: Any`.
const String kInstallerFirewallRuleName = 'Karmashala';

/// One interface address the machine could be dialled on.
typedef LanInterfaceAddress = ({String name, String ip});

/// Lists the machine's IPv4 LAN addresses. A seam: the real one wraps
/// `NetworkInterface.list`; tests hand back a scripted set of adapters.
typedef LanInterfaceLister = Future<List<LanInterfaceAddress>> Function();

/// Whether a self-connection to `ip:port` succeeds — the honest "can this
/// address actually be dialled" probe run after binding.
typedef ReachabilityProbe = Future<bool> Function(String ip, int port);

enum LocalRelayState { stopped, running, error }

/// One advertised way onto the local relay: `ws://<ip>:<port>`.
class LocalRelayEndpoint {
  const LocalRelayEndpoint({
    required this.ip,
    required this.interfaceName,
    required this.port,
    required this.primary,
    required this.reachable,
  });

  final String ip;
  final String interfaceName;
  final int port;

  /// The likeliest address for a phone to dial — physical-looking adapters
  /// and home-network ranges outrank WSL/Hyper-V/VPN virtual ones.
  final bool primary;

  /// Whether a self-connection through this address succeeded after binding.
  final bool reachable;

  Uri get url => Uri(scheme: 'ws', host: ip, port: port);

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'interface': interfaceName,
    'primary': primary,
    'reachable': reachable,
  };

  @override
  String toString() =>
      '$url ($interfaceName${primary ? ', primary' : ''}'
      '${reachable ? '' : ', unreachable'})';
}

/// What the relay is doing right now — what the desktop's settings row shows,
/// carried to it in `server.config.get`'s `localRelay`.
class LocalRelayStatus {
  const LocalRelayStatus({
    required this.state,
    this.boundPort,
    this.endpoints = const [],
    this.error,
    this.firewallHint = false,
  });

  const LocalRelayStatus.stopped() : this(state: LocalRelayState.stopped);

  final LocalRelayState state;

  /// The port actually bound while running (matters when 0 was asked for).
  final int? boundPort;

  /// Every address the relay can be dialled on, primary first.
  final List<LocalRelayEndpoint> endpoints;

  /// Why the relay is not running — e.g. the port is taken.
  final String? error;

  /// True when the scoped firewall rule could not be added (no admin is
  /// normal), so a client should hint at Windows Defender Firewall.
  final bool firewallHint;

  bool get running => state == LocalRelayState.running;

  /// The ws URL a phone should dial, or null when no address exists.
  Uri? get primaryUrl {
    for (final endpoint in endpoints) {
      if (endpoint.primary) return endpoint.url;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'state': state.name,
    'port': ?boundPort,
    'url': ?primaryUrl?.toString(),
    'endpoints': [for (final endpoint in endpoints) endpoint.toJson()],
    'error': ?error,
    'firewallHint': firewallHint,
  };
}

/// Runs the relay package's [RelayServer] inside the server.
class ServerLocalRelay {
  ServerLocalRelay({
    LanInterfaceLister? interfaces,
    ReachabilityProbe? probe,
    CommandRunner? firewall,
    String? executablePath,
    this.onLog,
  }) : _interfaces = interfaces ?? lanInterfaceAddresses,
       _probe = probe ?? _realProbe,
       // Private fields, named for callers.
       // ignore: prefer_initializing_formals
       _firewall = firewall,
       // ignore: prefer_initializing_formals — same.
       _executablePath = executablePath;

  final LanInterfaceLister _interfaces;
  final ReachabilityProbe _probe;

  /// Runs netsh. Null — every non-Windows platform and most tests — skips the
  /// firewall rule entirely.
  final CommandRunner? _firewall;
  final String? _executablePath;
  final void Function(String message)? onLog;

  RelayServer? _server;
  int? _requestedPort;
  String? _requestedAddress;

  LocalRelayStatus _status = const LocalRelayStatus.stopped();

  /// Serialises start/stop so a fast settings flip cannot overlap them.
  Future<void> _chain = Future<void>.value();

  LocalRelayStatus get status => _status;
  bool get isRunning => _status.running;

  /// Brings the relay up on [port] at [address] (restarting if either moved).
  /// A failed bind becomes an error status, never a throw.
  Future<void> ensureRunning({required int port, required String address}) {
    _chain = _chain
        .then((_) => _ensureRunning(port, address))
        .catchError((Object _) {});
    return _chain;
  }

  Future<void> stop() {
    _chain = _chain.then((_) => _stop()).catchError((Object _) {});
    return _chain;
  }

  Future<void> _ensureRunning(int port, String address) async {
    if (_server != null &&
        _requestedPort == port &&
        _requestedAddress == address) {
      return;
    }
    await _stop();
    _requestedPort = port;
    _requestedAddress = address;
    final RelayServer server;
    try {
      server = await RelayServer.bind(
        address: address,
        port: port,
        options: RelayOptions(
          loneTimeout: kLocalRelayLoneTimeout,
          onLog: onLog,
        ),
      );
    } on Object catch (error) {
      _log('bind failed on $address:$port: $error');
      _status = LocalRelayStatus(
        state: LocalRelayState.error,
        error: error is SocketException
            ? 'port $port is already in use by another program'
            : '$error',
      );
      // Asked again on the next change or retry, not held as bound.
      _requestedPort = null;
      _requestedAddress = null;
      return;
    }
    _server = server;
    _log('listening on $address:${server.port}');
    final firewallHint = !await _ensureFirewallRule(server.port);
    _status = LocalRelayStatus(
      state: LocalRelayState.running,
      boundPort: server.port,
      endpoints: await _enumerate(address, server.port),
      firewallHint: firewallHint,
    );
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    _requestedPort = null;
    _requestedAddress = null;
    if (server != null) {
      await server.close();
      _log('stopped');
    }
    _status = const LocalRelayStatus.stopped();
  }

  void _log(String message) => onLog?.call('local relay: $message');

  /// Where a phone can dial a relay bound at [address]: that address itself
  /// when it names one (loopback included — a test's), else every LAN
  /// address this machine has, best first.
  Future<List<LocalRelayEndpoint>> _enumerate(String address, int port) async {
    final bound = InternetAddress.tryParse(address);
    if (bound != null && !_isAny(bound)) {
      return [
        LocalRelayEndpoint(
          ip: bound.address,
          interfaceName: bound.isLoopback ? 'loopback' : 'bound',
          port: port,
          primary: true,
          reachable: true,
        ),
      ];
    }
    return lanEndpoints(
      port: port,
      interfaces: _interfaces,
      probe: _probe,
      onLog: _log,
    );
  }

  static bool _isAny(InternetAddress address) =>
      address == InternetAddress.anyIPv4 || address == InternetAddress.anyIPv6;

  static Future<bool> _realProbe(String ip, int port) async {
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(milliseconds: 800),
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  /// Tries to add the scoped inbound rule via netsh. Failing is normal (no
  /// admin) and NEVER elevates — the client shows a hint instead.
  Future<bool> _ensureFirewallRule(int port) async {
    final runner = _firewall;
    if (runner == null) return true;
    try {
      final shown = await runner.run(
        const CommandRequest(
          executable: 'netsh',
          arguments: [
            'advfirewall',
            'firewall',
            'show',
            'rule',
            'name=$kFirewallRuleName',
          ],
        ),
      );
      // The label is localised but the number is not, so this is the one
      // check that survives a non-English Windows.
      if (shown.ok && RegExp('\\b$port\\b').hasMatch(shown.stdout)) {
        return true;
      }
      if (shown.ok) {
        // A rule for some other port: replace it (delete needs the same
        // elevation as add, so a failure here just falls through to add).
        await runner.run(
          const CommandRequest(
            executable: 'netsh',
            arguments: [
              'advfirewall',
              'firewall',
              'delete',
              'rule',
              'name=$kFirewallRuleName',
            ],
          ),
        );
      }
      final exe = _executablePath ?? Platform.resolvedExecutable;
      final added = await runner.run(
        CommandRequest(
          executable: 'netsh',
          arguments: [
            'advfirewall',
            'firewall',
            'add',
            'rule',
            'name=$kFirewallRuleName',
            'dir=in',
            'action=allow',
            'program=$exe',
            'protocol=TCP',
            'localport=$port',
          ],
        ),
      );
      if (added.ok) return true;
      // A refused add is not a closed firewall: the installer's own rule may
      // already allow this program, and the hint would send the owner after
      // nothing.
      if (await _programIsAlreadyAllowed(runner)) return true;
      _log('netsh refused the firewall rule (no admin?)');
      return false;
    } on Object catch (error) {
      _log('netsh unavailable: $error');
      return false;
    }
  }

  /// Whether an inbound rule already names this executable. Matched on the
  /// path alone: every label netsh prints is localised, the path is not.
  Future<bool> _programIsAlreadyAllowed(CommandRunner runner) async {
    final exe = _executablePath ?? Platform.resolvedExecutable;
    try {
      final shown = await runner.run(
        const CommandRequest(
          executable: 'netsh',
          arguments: [
            'advfirewall',
            'firewall',
            'show',
            'rule',
            'name=$kInstallerFirewallRuleName',
          ],
        ),
      );
      if (!shown.ok) return false;
      final covered = shown.stdout.toLowerCase().contains(exe.toLowerCase());
      if (covered) _log('already allowed inbound by the installer rule');
      return covered;
    } on Object catch (error) {
      _log('firewall rule lookup failed: $error');
      return false;
    }
  }
}

/// Every address in [interfaces] as a way onto a relay listening on all of
/// them at [port], each probed, best first and the first one primary.
Future<List<LocalRelayEndpoint>> lanEndpoints({
  required int port,
  LanInterfaceLister interfaces = lanInterfaceAddresses,
  required ReachabilityProbe probe,
  void Function(String message)? onLog,
}) async {
  List<LanInterfaceAddress> addresses;
  try {
    addresses = await interfaces();
  } on Object catch (error) {
    onLog?.call('interface enumeration failed: $error');
    addresses = const [];
  }
  // One endpoint per IP; the first interface naming it wins.
  final seen = <String>{};
  addresses = [
    for (final address in addresses)
      if (seen.add(address.ip)) address,
  ];
  final reachable = await Future.wait(
    addresses.map((address) async {
      try {
        return await probe(address.ip, port);
      } on Object {
        return false;
      }
    }),
  );
  final scored = [
    for (var i = 0; i < addresses.length; i++)
      (
        address: addresses[i],
        reachable: reachable[i],
        score: lanAddressScore(addresses[i], reachable: reachable[i]),
      ),
  ]..sort((a, b) => a.score.compareTo(b.score));
  return [
    for (var i = 0; i < scored.length; i++)
      LocalRelayEndpoint(
        ip: scored[i].address.ip,
        interfaceName: scored[i].address.name,
        port: port,
        primary: i == 0,
        reachable: scored[i].reachable,
      ),
  ];
}

/// This machine's IPv4 addresses, loopback and link-local left out.
Future<List<LanInterfaceAddress>> lanInterfaceAddresses() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses)
        (name: interface.name, ip: address.address),
  ];
}

/// Lower is likelier to be what a phone on this network can dial:
/// unreachable last, virtual adapters (WSL, Hyper-V, VPNs…) behind physical
/// ones, home ranges before others.
int lanAddressScore(LanInterfaceAddress address, {bool reachable = true}) {
  var score = 0;
  if (!reachable) score += 1000;
  const virtualMarkers = [
    'wsl',
    'vethernet',
    'hyper-v',
    'virtualbox',
    'vmware',
    'docker',
    'tailscale',
    'zerotier',
    'vpn',
    'loopback',
    'bluetooth',
    'utun',
    'bridge',
  ];
  final name = address.name.toLowerCase();
  if (virtualMarkers.any(name.contains)) score += 100;
  final ip = address.ip;
  if (ip.startsWith('192.168.')) {
    // The likeliest home LAN.
  } else if (ip.startsWith('10.')) {
    score += 10;
  } else if (_is172Private(ip)) {
    score += 20; // WSL/Hyper-V NATs love this range.
  } else {
    score += 30;
  }
  return score;
}

bool _is172Private(String ip) {
  if (!ip.startsWith('172.')) return false;
  final second = int.tryParse(ip.split('.')[1]);
  return second != null && second >= 16 && second <= 31;
}
