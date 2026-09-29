import 'dart:async';

import 'package:karmashala_core/logging.dart' show AppLogger;
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kProtocolVersion;
import 'package:karmashala_remote/client.dart';

/// A Karmashala server on another machine (slice 5e), reached the way the
/// phone reaches one — its LAN listener, a beacon sighting, its announced LAN
/// address or a relay, the sealed channel — and switched to the host
/// protocol. Nothing is started or supervised: it is only dialled.
///
/// Owns the process's one [LanPathScout] while this machine is in use: it
/// starts listening for beacons here, so sightings have gathered by the first
/// dial, and stops at [close]. The local server never builds one of these, so
/// the scout never runs for it.
class RemoteServerAccess implements HostSessionAccess {
  RemoteServerAccess({
    required this.hostId,
    required this.hostName,
    required this.store,
    DesktopServerDialer? dialer,
    void Function(String message)? onLog,
  }) : _dialer =
           dialer ??
           DesktopServerDialer(
             store: store,
             scout: LanPathScout(onLog: onLog ?? _defaultLog),
             onLog: onLog ?? _defaultLog,
           ) {
    unawaited(_dialer.startScouting());
  }

  final String hostId;
  final String hostName;

  /// Where the pairing record lives; read on every dial, since each dial
  /// moves its generation on and may learn new routes.
  final CompanionStore store;
  final DesktopServerDialer _dialer;

  static final AppLogger _log = AppLogger.named('remote_dial');
  static void _defaultLog(String message) => _log.info(message);

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

  /// This machine is no longer in use: beacon listening stops. Links already
  /// open are their owners' to close. Today a switch relaunches the app, so
  /// the process ending does this; step 13's per-server `close()` calls it.
  Future<void> close() => _dialer.close();
}
