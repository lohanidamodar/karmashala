import 'package:karmashala_host/protocol.dart';

import 'companion_port.dart';
import 'remote_pairing.dart';
import 'host_deploy_target.dart';
import 'ssh_host.dart';

/// Where a phone reaches one box, and how sure we are that it can.
///
/// **Nothing here discovers an address.** The person typed it to reach the box
/// over SSH and the desktop stored it; a host asked for its own public address
/// would be guessing past NAT, several interfaces and a provider's floating IP.
/// The one party that knows it for certain is the one that connected, so this
/// carries that value onward rather than deriving a new one.
class CompanionEndpoint {
  const CompanionEndpoint({
    required this.address,
    required this.port,
    required this.hostName,
    required this.reachable,
    required this.reason,
  });

  /// The same address the SSH connection used — `SshHost.host`, verbatim.
  final String address;

  /// The companion port, which is **not** the SSH port: frames go straight to
  /// the host over TCP, and SSH only ever provisioned the machine.
  final int port;

  /// What the box calls itself, for a phone choosing between several.
  final String hostName;

  /// Whether a dial from here actually got through. False is still an endpoint
  /// worth showing — the address and port are right, something in between is
  /// not — and the phone may sit somewhere this desktop does not.
  final bool reachable;

  /// One sentence about the last reading, with its remedy when it has one.
  final String reason;

  /// What a person types into the phone, and what a QR would encode.
  String get authority => '$address:$port';

  @override
  String toString() => 'CompanionEndpoint($authority, ${reachable ? 'reachable' : 'unproven'})';
}

/// Prepares one box to be reached by a phone, and answers where.
///
/// Composes the two halves the desktop already has: the address it connected
/// with, and the port check that opens the firewall only against evidence and
/// proves the result with a dial.
class SshCompanionSetup {
  SshCompanionSetup({
    required this.host,
    required this.target,
    required this.remotePath,
    CompanionPortSetup? ports,
    RemotePairing? pairing,
    this.port = kHostCompanionPort,
  }) : _ports = ports ?? CompanionPortSetup(target: target),
       _pairing =
           pairing ?? RemotePairing(target: target, remotePath: remotePath);

  final SshHost host;
  final HostDeployTarget target;

  /// The executable `HostDeployment.remotePath` named — the one a pane runs, so
  /// a pairing cannot land on a different host than the sessions.
  final String remotePath;

  final int port;
  final CompanionPortSetup _ports;
  final RemotePairing _pairing;

  /// The host must already be deployed and serving: a dial at a port nothing
  /// listens on says "shut" about something that was never going to answer.
  Future<CompanionEndpoint> prepare() async {
    final opening = await _ports.ensureOpen(port);
    return CompanionEndpoint(
      address: host.host,
      port: port,
      hostName: host.name,
      reachable: opening.isReachable,
      reason: opening.command == null
          ? opening.reason
          : '${opening.reason} Run: ${opening.command}',
    );
  }

  /// Everything a person needs in one go: where the phone should dial, and the
  /// code to type there.
  ///
  /// The port is opened **before** the window, because a code that expires
  /// while somebody fixes a firewall is a code they have to fetch again. An
  /// unreachable port does not stop it: the phone may sit somewhere this
  /// desktop does not, and the endpoint says what it knows either way.
  Future<({CompanionEndpoint endpoint, PairingWindow window})> invite({
    required int capabilities,
    String relay = '',
  }) async {
    final endpoint = await prepare();
    final window = await _pairing.open(capabilities: capabilities, relay: relay);
    return (endpoint: endpoint, window: window);
  }
}
