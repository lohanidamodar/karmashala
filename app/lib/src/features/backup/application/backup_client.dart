import 'package:flutter/foundation.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ServerMethod;
import 'package:riverpod/riverpod.dart';

import '../../remote/application/host_companion_providers.dart';

/// How often the server backs up on its own; the names are the wire's.
enum BackupFrequency {
  off('Off'),
  daily('Daily'),
  weekly('Weekly');

  const BackupFrequency(this.label);
  final String label;

  static BackupFrequency parse(Object? raw) => values.firstWhere(
    (value) => value.name == raw,
    orElse: () => BackupFrequency.off,
  );
}

/// What `server.backup.schedule.get` answered.
@immutable
class BackupScheduleReading {
  const BackupScheduleReading({
    required this.frequency,
    required this.keep,
    required this.folder,
    required this.newest,
    required this.lastError,
    required this.lastRestore,
    required this.pendingRestore,
  });

  factory BackupScheduleReading.fromJson(Map<String, Object?> json) {
    final last = json['last'];
    final restore = json['lastRestore'];
    final folder = json['folder'];
    final keep = json['keep'];
    return BackupScheduleReading(
      frequency: BackupFrequency.parse(json['frequency']),
      keep: keep is int ? keep : 7,
      folder: folder is String ? folder : null,
      newest: DateTime.tryParse('${json['newest']}'),
      lastError: last is Map && last['error'] is String
          ? last['error'] as String
          : null,
      lastRestore: restore is Map
          ? (
              at: DateTime.tryParse('${restore['restoredAt']}'),
              backupCreatedAt: DateTime.tryParse(
                '${restore['backupCreatedAt']}',
              ),
              before: '${restore['before'] ?? ''}',
            )
          : null,
      pendingRestore: json['pendingRestore'] == true,
    );
  }

  final BackupFrequency frequency;
  final int keep;
  final String? folder;

  /// The newest backup in [folder].
  final DateTime? newest;

  /// Why the last scheduled backup failed, since the server started.
  final String? lastError;
  final ({DateTime? at, DateTime? backupCreatedAt, String before})? lastRestore;

  /// A restore is staged and switches in when the server next starts.
  final bool pendingRestore;
}

/// The parts of a backup's manifest Settings shows.
@immutable
class BackupSummary {
  const BackupSummary({
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.dataDirectory,
    required this.counts,
    required this.fileCount,
    required this.fileBytes,
    required this.checkpointRefs,
    required this.repositories,
    required this.skipped,
  });

  factory BackupSummary.fromJson(Map<String, Object?> json) {
    final counts = json['counts'];
    final refs = json['checkpoints'];
    final skipped = json['skipped'];
    return BackupSummary(
      appVersion: '${json['appVersion'] ?? '?'}',
      schemaVersion: _int(json['schemaVersion']),
      createdAt: DateTime.tryParse('${json['createdAt']}'),
      dataDirectory: '${json['dataDirectory'] ?? ''}',
      counts: {
        if (counts is Map)
          for (final entry in counts.entries)
            if (entry.key is String) entry.key as String: _int(entry.value),
      },
      fileCount: _int(json['fileCount']),
      fileBytes: _int(json['fileBytes']),
      checkpointRefs: refs is List ? refs.length : 0,
      repositories: refs is List
          ? {
              for (final ref in refs)
                if (ref is Map) '${ref['repositoryPath']}',
            }.length
          : 0,
      skipped: skipped is List ? skipped.length : 0,
    );
  }

  final String appVersion;
  final int schemaVersion;
  final DateTime? createdAt;
  final String dataDirectory;
  final Map<String, int> counts;
  final int fileCount;
  final int fileBytes;
  final int checkpointRefs;
  final int repositories;
  final int skipped;

  int count(String table) => counts[table] ?? 0;

  static int _int(Object? value) => value is int ? value : 0;
}

/// The server's backup calls, through [call] (`serverCall`).
class BackupClient {
  const BackupClient(this.call);

  final Future<Map<String, Object?>> Function(
    String method, [
    Map<String, Object?> arguments,
  ])
  call;

  Future<BackupScheduleReading> schedule() async =>
      BackupScheduleReading.fromJson(
        await call(ServerMethod.backupScheduleGet),
      );

  Future<BackupScheduleReading> setSchedule({
    required BackupFrequency frequency,
    required int keep,
    String? folder,
  }) async => BackupScheduleReading.fromJson(
    await call(ServerMethod.backupScheduleSet, {
      'frequency': frequency.name,
      'keep': keep,
      'folder': ?folder,
    }),
  );

  /// The archive's path, and what is in it.
  Future<({String path, BackupSummary summary})> create(String folder) async {
    final answer = await call(ServerMethod.backupCreate, {'folder': folder});
    return (
      path: '${answer['path']}',
      summary: BackupSummary.fromJson(_map(answer['manifest'])),
    );
  }

  /// What [archive] holds, and why the server would refuse it, or null.
  Future<({BackupSummary summary, String? refusal})> inspect(
    String archive,
  ) async {
    final answer = await call(ServerMethod.backupInspect, {'archive': archive});
    final refusal = answer['refusal'];
    return (
      summary: BackupSummary.fromJson(_map(answer['manifest'])),
      refusal: refusal is String ? refusal : null,
    );
  }

  /// Stages [archive]; it switches in when the server next starts.
  Future<({int schemaFrom, int schemaTo})> restore(String archive) async {
    final answer = await call(ServerMethod.backupRestore, {'archive': archive});
    return (
      schemaFrom: answer['schemaFrom'] as int? ?? 0,
      schemaTo: answer['schemaTo'] as int? ?? 0,
    );
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map<String, Object?> ? value : const {};
}

final backupClientProvider = Provider<BackupClient>((ref) {
  final link = ref.watch(hostCompanionLinkProvider);
  return BackupClient(
    (method, [arguments = const {}]) => link.serverCall(method, arguments),
  );
});

/// Read when Settings → Data is shown; invalidated after each change.
final backupScheduleProvider =
    FutureProvider.autoDispose<BackupScheduleReading>(
      (ref) => ref.watch(backupClientProvider).schedule(),
    );

/// Waits, up to [within], for the link to this machine's server to be back
/// after a restart: it reattaches a moment after the server is up.
final serverLinkBackProvider =
    Provider<Future<void> Function({Duration within})>((ref) {
      final link = ref.watch(hostCompanionLinkProvider);
      return ({Duration within = const Duration(seconds: 15)}) async {
        final deadline = DateTime.now().add(within);
        while (!link.connected && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      };
    });
