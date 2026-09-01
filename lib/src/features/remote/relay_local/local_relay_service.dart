/// The embedded local relay: the app runs `RelayServer` in-process so remote
/// access works on anyone's computer with one click — no hosted relay, no adb.
///
/// Never crashes the app: a failed bind, a refused netsh, a machine with no
/// network are all surfaced as [LocalRelayStatus], not thrown.
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala_relay/karmashala_relay.dart';

import '../../../core/process/command_runner.dart';

/// The port the local relay binds unless the user moves it. Deliberately the
/// relay package's own default, pinned equal by a test.
const int kDefaultLocalRelayPort = kDefaultRelayPort;

/// How long the embedded relay lets a socket wait alone at a rendezvous
/// before hanging up on it. Zero means never, and that is deliberate.
///
/// The relay package's two-minute default is right for a SHARED relay, where
/// a lone socket may be a stranger pinning a rendezvous nobody will ever come
/// to. This relay runs inside the desktop and serves only it: every socket
/// waiting alone here is one of this desktop's own rendezvous listeners,
/// waiting — correctly — for a phone that may be away for hours.
///
/// Measured on the owner's machine while the phone would not connect: three
/// listeners, each evicted and re-dialled every 120.3 seconds, 58 times in a
/// single run of the app, and the whole `remote:` log for forty minutes was
/// `a socket is waiting (3 held)` repeating. Each eviction is a window in
/// which the desktop is absent from its own rendezvous, and a phone arriving
/// in one finds nobody there.
const Duration kLocalRelayLoneTimeout = Duration.zero;

/// The scoped inbound firewall rule the service tries to add on Windows.
const String kFirewallRuleName = 'Karmashala local relay';

/// The inbound rule the INSTALLER writes, which the app cannot write for
/// itself without elevation. Program-scoped and `LocalPort: Any`, so it
/// already covers this relay on whatever port it binds.
const String kInstallerFirewallRuleName = 'Karmashala';

/// One interface address the machine could be dialled on.
typedef LanInterfaceAddress = ({String name, String ip});

/// Lists the machine's IPv4 LAN addresses. A seam: the real one wraps
/// `NetworkInterface.list`; tests hand back a scripted set of adapters.
typedef LanInterfaceLister = Future<List<LanInterfaceAddress>> Function();

/// Answers whether a self-connection to `ip:port` succeeds — the honest
/// "can this address actually be dialled" probe run after binding.
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

  @override
  String toString() =>
      '$url ($interfaceName${primary ? ', primary' : ''}'
      '${reachable ? '' : ', unreachable'})';
}

/// What the relay is doing right now — everything the settings row shows.
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

  /// The port actually bound while running (matters when 0 was requested).
  final int? boundPort;

  /// Every LAN address the relay can be dialled on, primary flagged.
  final List<LocalRelayEndpoint> endpoints;

  /// Why the relay is not running — e.g. the port is taken.
  final String? error;

  /// True when the scoped firewall rule could not be added (no admin is
  /// normal), so the UI should hint at Windows Defender Firewall.
  final bool firewallHint;

  /// The ws URL a phone should dial, or null when no LAN address exists.
  Uri? get primaryUrl {
    for (final endpoint in endpoints) {
      if (endpoint.primary) return endpoint.url;
    }
    return null;
  }
}

/// Runs the relay package's [RelayServer] inside the desktop app.
class LocalRelayService {
  LocalRelayService({
    Object bindAddress = '0.0.0.0',
    LanInterfaceLister? interfaces,
    ReachabilityProbe? probe,
    CommandRunner? firewall,
    String? executablePath,
    this.onLog,
  }) : // Private fields, named for callers.
       // ignore: prefer_initializing_formals
       _bindAddress = bindAddress,
       _interfaces = interfaces ?? _realInterfaces,
       _probe = probe ?? _realProbe,
       // ignore: prefer_initializing_formals — same.
       _firewall = firewall,
       // ignore: prefer_initializing_formals — same.
       _executablePath = executablePath;

  /// `0.0.0.0` in production; tests bind loopback so nothing leaves the box.
  final Object _bindAddress;
  final LanInterfaceLister _interfaces;
  final ReachabilityProbe _probe;

  /// Runs netsh. Null — every non-Windows platform and most tests — skips the
  /// firewall rule entirely.
  final CommandRunner? _firewall;
  final String? _executablePath;
  final void Function(String message)? onLog;

  RelayServer? _server;
  int? _requestedPort;

  LocalRelayStatus _status = const LocalRelayStatus.stopped();
  final StreamController<LocalRelayStatus> _changes =
      StreamController<LocalRelayStatus>.broadcast();

  /// Serialises start/stop so a fast mode flip cannot overlap them.
  Future<void> _chain = Future<void>.value();

  LocalRelayStatus get status => _status;
  Stream<LocalRelayStatus> get changes => _changes.stream;
  bool get isRunning => _status.state == LocalRelayState.running;

  /// Brings the relay up on [port] (restarting if the port moved). Bind
  /// failure becomes an error status, never a throw.
  Future<void> ensureRunning(int port) {
    _chain = _chain.then((_) => _ensureRunning(port)).catchError((Object _) {});
    return _chain;
  }

  Future<void> stop() {
    _chain = _chain.then((_) => _stop()).catchError((Object _) {});
    return _chain;
  }

  Future<void> _ensureRunning(int port) async {
    if (_server != null && _requestedPort == port) return;
    await _stop();
    _requestedPort = port;
    final RelayServer server;
    try {
      server = await RelayServer.bind(
        address: _bindAddress,
        port: port,
        options: RelayOptions(
          loneTimeout: kLocalRelayLoneTimeout,
          onLog: onLog,
        ),
      );
    } on Object catch (error) {
      _log('bind failed on port $port: $error');
      _set(
        LocalRelayStatus(
          state: LocalRelayState.error,
          error: error is SocketException
              ? 'port $port is already in use by another program'
              : '$error',
        ),
      );
      return;
    }
    _server = server;
    _log('listening on port ${server.port}');
    final firewallHint = !await _ensureFirewallRule(server.port);
    final endpoints = await _enumerate(server.port);
    _set(
      LocalRelayStatus(
        state: LocalRelayState.running,
        boundPort: server.port,
        endpoints: endpoints,
        firewallHint: firewallHint,
      ),
    );
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    _requestedPort = null;
    if (server != null) {
      await server.close();
      _log('stopped');
    }
    if (_status.state != LocalRelayState.stopped) {
      _set(const LocalRelayStatus.stopped());
    }
  }

  void _set(LocalRelayStatus status) {
    _status = status;
    if (!_changes.isClosed) _changes.add(status);
  }

  void _log(String message) => onLog?.call('local relay: $message');

  // --- LAN addresses ---------------------------------------------------------

  Future<List<LocalRelayEndpoint>> _enumerate(int port) async {
    List<LanInterfaceAddress> addresses;
    try {
      addresses = await _interfaces();
    } on Object catch (error) {
      _log('interface enumeration failed: $error');
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
          return await _probe(address.ip, port);
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
          score: _score(addresses[i], reachable[i]),
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

  /// Lower is likelier: unreachable last, virtual adapters (WSL, Hyper-V,
  /// VPNs…) behind physical ones, home ranges before carrier-grade ones.
  static int _score(LanInterfaceAddress address, bool reachable) {
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

  static bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final second = int.tryParse(ip.split('.')[1]);
    return second != null && second >= 16 && second <= 31;
  }

  static Future<List<LanInterfaceAddress>> _realInterfaces() async {
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

  // --- Firewall --------------------------------------------------------------

  /// Tries to add the scoped inbound rule via netsh; returns whether the rule
  /// is believed present. Failing is normal (no admin) and NEVER elevates —
  /// the caller shows a hint instead.
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
      // A refused add is not the same as a closed firewall, and saying so
      // sent the owner after a firewall that was never shut. Measured on
      // their machine: the app could not write its own rule, logged
      // "netsh refused the firewall rule (no admin?)", and put "If the phone
      // can't connect, allow Karmashala in Windows Defender Firewall" on
      // screen — while the phone was reaching the relay on this very port
      // and the installer's own rule was allowing it.
      if (await _programIsAlreadyAllowed(runner)) return true;
      _log('netsh refused the firewall rule (no admin?)');
      return false;
    } on Object catch (error) {
      _log('netsh unavailable: $error');
      return false;
    }
  }

  /// Whether an existing inbound rule already names this executable.
  ///
  /// Matched on the program path alone: rule names and every label netsh
  /// prints are localised on a non-English Windows, and the path is not.
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
