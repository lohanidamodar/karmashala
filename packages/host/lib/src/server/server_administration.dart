import 'package:karmashala_remote/remote.dart';

import '../agents/server_agents.dart';
import '../companion/daemon_companion.dart';
import '../protocol/messages.dart';
import 'server_admin.dart';

/// The daemon's answers to `serverCall`: its paired devices and revoking one
/// (through the companion, so a revoked phone's links drop at once), and the
/// agent CLIs on this machine.
class ServerAdministration implements ServerAdmin {
  ServerAdministration({
    required this.companion,
    required this.agents,
    required this.name,
    required this.bind,
    required this.standalone,
  });

  /// Null when phones cannot be served (the companion did not start).
  final DaemonCompanion? companion;
  final ServerAgents agents;

  /// What this server is called, where its phone listener binds, and whether
  /// it runs on its own.
  final String name;
  final String bind;
  final bool standalone;

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> arguments,
  ) async {
    switch (method) {
      case ServerMethod.serverInfo:
        final serving = companion?.service;
        final relay = companion?.config.relay;
        return {
          'name': name,
          'standalone': standalone,
          'companion': {
            'serving': serving != null && serving.isRunning,
            'port': ?companion?.port,
            'bind': bind,
            'relay': ?(relay == null ? null : scrubRelayLog('$relay')),
          },
        };
      case ServerMethod.devicesList:
        return {
          'devices': [
            for (final device in _companion().devices()) deviceJson(device),
          ],
        };
      case ServerMethod.devicesRevoke:
        final deviceId = arguments['deviceId'];
        if (deviceId is! String || deviceId.trim().isEmpty) {
          throw const ServerCallRefused('name the device to revoke');
        }
        final PairedDevice device;
        try {
          device = await _companion().revokeDevice(deviceId.trim());
        } on StateError catch (error) {
          throw ServerCallRefused(error.message);
        }
        return {'device': deviceJson(device)};
      case ServerMethod.agentsList:
        return {
          'agents': [
            for (final agent in agents.recorded()) agents.toJson(agent),
          ],
        };
      case ServerMethod.agentsRefresh:
        final scan = await agents.refresh();
        return {
          'agents': [for (final agent in scan.agents) agents.toJson(agent)],
          'summary': scan.summary,
        };
      default:
        throw ServerCallRefused('this server does not answer "$method"');
    }
  }

  DaemonCompanion _companion() =>
      companion ??
      (throw const ServerCallRefused(
        'this server is not serving phones — its log says why',
      ));

  /// [device] as the wire carries it: never its key, its push token or a
  /// relay's access token.
  static Map<String, Object?> deviceJson(PairedDevice device) {
    final relay = device.relayUrl;
    return {
      'id': device.id,
      'name': device.name,
      'capabilities': [
        for (final capability in device.capabilities.granted) capability.wire,
      ],
      'pairedAt': device.createdAt.toUtc().toIso8601String(),
      'lastSeenAt': ?device.lastSeenAt?.toUtc().toIso8601String(),
      'revoked': device.revoked,
      'relay': ?(relay == null ? null : scrubRelayLog(relay)),
    };
  }
}
