import 'dart:io';

import 'package:karmashala_remote/remote.dart';

import '../agents/server_agents.dart';
import '../backup/backup_restore.dart';
import '../backup/backup_writer.dart' show BackupRefused;
import '../backup/server_backups.dart';
import '../companion/daemon_companion.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'server_admin.dart';
import 'server_config.dart';
import 'server_config_service.dart';
import 'server_storage.dart';

/// The daemon's answers to `serverCall`: its paired devices and revoking one
/// (through the companion, so a revoked phone's links drop at once), the
/// agent CLIs on this machine, and its config.
class ServerAdministration implements ServerAdmin {
  ServerAdministration({
    required this.companion,
    required this.agents,
    required this.config,
    required this.dataDirectory,
    this.storage,
    this.backups,
  });

  /// Settings → Data's backups; null refuses those calls.
  final ServerBackups? backups;

  /// What Settings → Server → Storage reads and clears; null refuses those
  /// calls.
  final ServerStorage? storage;

  /// Null when phones cannot be served (the companion did not start).
  final DaemonCompanion? companion;
  final ServerAgents agents;

  /// `server.json` and what it decides.
  final ServerConfigService config;

  /// Where the server keeps its store and config.
  final String dataDirectory;

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> arguments,
  ) async {
    switch (method) {
      case ServerMethod.serverInfo:
        final serving = companion?.service;
        final relay = companion?.config.relay;
        final settings = config.settings;
        return {
          'name': settings.name,
          'dataDirectory': dataDirectory,
          'companion': {
            'serving': serving != null && serving.isRunning,
            'port': ?companion?.port,
            'bind': settings.bind,
            'relay': ?(relay == null ? null : scrubRelayLog('$relay')),
            'localRelay': ?companion?.localRelayStatus.toJson(),
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
      case ServerMethod.configGet:
        return _withLocalRelay(config.describe());
      case ServerMethod.configSet:
        final patch = arguments['patch'];
        if (patch is! Map<String, Object?>) {
          throw const ServerCallRefused(
            'name the fields to change, shaped like server.json',
          );
        }
        try {
          return _withLocalRelay(await config.set(patch));
        } on ServerConfigError catch (error) {
          throw ServerCallRefused('$error');
        } on FileSystemException catch (error) {
          throw ServerCallRefused(
            'server.json could not be written (${error.message})',
          );
        }
      case ServerMethod.storage:
        return _storage().read();
      case ServerMethod.toolImagesClear:
        return _storage().clearToolImages();
      case ServerMethod.toolImagesSweep:
        return _storage().sweepToolImages();
      case ServerMethod.backupCreate:
        final folder = _path(
          arguments,
          'folder',
          'name the folder to back up into',
        );
        return _refusing(() async {
          final written = await _backups().create(folder);
          return {
            'path': written.path,
            'manifest': written.manifest.summaryJson(),
          };
        });
      case ServerMethod.backupInspect:
        final archive = _path(arguments, 'archive', 'name the backup to read');
        return _refusing(() async {
          final read = await inspectBackup(
            archive,
            knownSchema: _backups().database.schemaVersion,
          );
          return {
            'manifest': read.manifest.summaryJson(),
            'refusal': ?read.refusal,
          };
        });
      case ServerMethod.backupRestore:
        final archive = _path(
          arguments,
          'archive',
          'name the backup to restore',
        );
        return _refusing(() async {
          final staged = await stageRestore(
            archive,
            dataDirectory: _backups().dataDirectory,
          );
          return {
            'staged': staged.staged,
            'schemaFrom': staged.schemaFrom,
            'schemaTo': staged.schemaTo,
          };
        });
      case ServerMethod.backupScheduleGet:
        return _backups().describe();
      case ServerMethod.backupScheduleSet:
        return _backups().setSchedule(arguments);
      default:
        throw ServerCallRefused('this server does not answer "$method"');
    }
  }

  ServerBackups _backups() =>
      backups ?? (throw const ServerCallRefused('this server cannot back up'));

  static String _path(
    Map<String, Object?> arguments,
    String name,
    String refusal,
  ) {
    final value = arguments[name];
    if (value is! String || value.trim().isEmpty) {
      throw ServerCallRefused(refusal);
    }
    return value.trim();
  }

  /// [work]'s answer, its refusals and file errors in words for the person.
  static Future<Map<String, Object?>> _refusing(
    Future<Map<String, Object?>> Function() work,
  ) async {
    try {
      return await work();
    } on BackupRefused catch (error) {
      throw ServerCallRefused(error.message);
    } on FileSystemException catch (error) {
      throw ServerCallRefused(
        '${error.message}${error.path == null ? '' : ' (${error.path})'}',
      );
    }
  }

  ServerStorage _storage() =>
      storage ??
      (throw const ServerCallRefused('this server cannot read its storage'));

  /// The config's answer, with what the LAN relay it asks for is doing:
  /// the desktop's settings row and its pairing tab read it.
  Map<String, Object?> _withLocalRelay(Map<String, Object?> described) => {
    ...described,
    'localRelay': ?companion?.localRelayStatus.toJson(),
  };

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
