import 'package:flutter/foundation.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ServerMethod;
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../remote/application/host_companion_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../settings/application/settings_controller.dart';

/// What `server.storage` answered: the database, its largest tables (null
/// when the server's SQLite cannot say), and the tool-image cache.
@immutable
class ServerStorageReading {
  const ServerStorageReading({
    required this.databaseBytes,
    required this.tables,
    required this.toolImageFiles,
    required this.toolImageBytes,
  });

  factory ServerStorageReading.fromJson(Map<String, Object?> json) {
    final images = json['toolImages'];
    final cache = images is Map ? images : const {};
    final tables = json['tables'];
    return ServerStorageReading(
      databaseBytes: _int(json['databaseBytes']),
      tables: tables is List
          ? [
              for (final table in tables)
                if (table is Map && table['name'] is String)
                  (name: table['name'] as String, bytes: _int(table['bytes'])),
            ]
          : null,
      toolImageFiles: _int(cache['files']),
      toolImageBytes: _int(cache['bytes']),
    );
  }

  final int databaseBytes;
  final List<({String name, int bytes})>? tables;
  final int toolImageFiles;
  final int toolImageBytes;

  static int _int(Object? value) => value is int ? value : 0;
}

/// The server's storage calls, through [call] (`serverCall`).
class ServerStorageClient {
  const ServerStorageClient(this.call);

  final Future<Map<String, Object?>> Function(String method) call;

  Future<ServerStorageReading> read() async =>
      ServerStorageReading.fromJson(await call(ServerMethod.storage));

  /// How many cached images went.
  Future<int> clearToolImages() async =>
      (await call(ServerMethod.toolImagesClear))['removed'] as int? ?? 0;

  Future<int> sweepToolImages() async =>
      (await call(ServerMethod.toolImagesSweep))['removed'] as int? ?? 0;
}

final serverStorageClientProvider = Provider<ServerStorageClient>((ref) {
  final link = ref.watch(hostCompanionLinkProvider);
  return ServerStorageClient((method) => link.serverCall(method));
});

/// Read when Settings → Server → Storage is shown; invalidated after a clear.
final serverStorageProvider = FutureProvider.autoDispose<ServerStorageReading>(
  (ref) => ref.watch(serverStorageClientProvider).read(),
);

/// Ended sessions started more than the set number of days ago: what Clean
/// up offers. Counted again when a session row changes.
final oldEndedSessionsProvider = Provider.autoDispose<List<Session>>((ref) {
  final sessions = ref.watch(sessionsDataProvider);
  final changes = sessions.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(changes.cancel);
  final days = ref.watch(
    settingsControllerProvider.select((s) => s.endedSessionsOlderThanDays),
  );
  final cutoff = ref
      .watch(clockProvider)
      .nowUtc()
      .subtract(Duration(days: days));
  return [
    for (final session in sessions.getAll())
      if (session.status.isEnded && session.createdAt.isBefore(cutoff)) session,
  ];
});
