import 'dart:async';

import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kProtocolVersion;
import 'package:karmashala_remote/client.dart';

/// A Karmashala server on another machine (slice 5e), reached the way the
/// phone reaches one — its LAN listener or a relay, the sealed channel —
/// and switched to the host protocol. Nothing is started or supervised: it
/// is only dialled.
class RemoteServerAccess implements HostSessionAccess {
  RemoteServerAccess({
    required this.hostId,
    required this.hostName,
    required this.store,
    DesktopServerDialer? dialer,
  }) : _dialer = dialer ?? DesktopServerDialer(store: store);

  final String hostId;
  final String hostName;

  /// Where the pairing record lives; read on every dial, since each dial
  /// moves its generation on.
  final CompanionStore store;
  final DesktopServerDialer _dialer;

  @override
  String get address => hostName;

  @override
  Stream<void> get reconnected => const Stream<void>.empty();

  /// Always "ready": whether it answers is what [exec] finds out.
  @override
  Future<HostDeployment> deployment() async => HostDeployment(
    status: HostDeploymentStatus.ready,
    observedAt: DateTime.now().toUtc(),
    reason: 'a server on another machine, dialled over the sealed channel',
    remotePath: 'karmashala_host',
    protocolVersion: kProtocolVersion,
  );

  @override
  Future<RemoteChannel> exec(String command) async {
    final record = (await CompanionConnections.load(store)).byHost(hostId);
    if (record == null) {
      throw HostLinkException('$hostName is no longer paired with this app.');
    }
    try {
      return SealedHostChannel(await _dialer.dial(record));
    } on DesktopConnectException catch (error) {
      throw HostLinkException(error.message);
    }
  }
}
