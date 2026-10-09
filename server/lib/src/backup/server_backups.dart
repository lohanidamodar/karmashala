import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import 'backup_restore.dart';
import 'backup_writer.dart';

/// How often the server backs up on its own.
enum BackupFrequency {
  off(null),
  daily(Duration(days: 1)),
  weekly(Duration(days: 7));

  const BackupFrequency(this.every);
  final Duration? every;

  static BackupFrequency parse(Object? raw) => values.firstWhere(
    (value) => value.name == raw,
    orElse: () => BackupFrequency.off,
  );
}

/// The schedule as Settings → Data sets it, kept in the store's
/// `app_metadata` under [key].
class BackupSchedule {
  const BackupSchedule({
    this.frequency = BackupFrequency.off,
    this.keep = defaultKeep,
    this.folder,
  });

  static const key = 'backup.schedule';
  static const defaultKeep = 7;
  static const minKeep = 1;
  static const maxKeep = 100;

  factory BackupSchedule.fromJson(Object? raw) {
    if (raw is! Map) return const BackupSchedule();
    final keep = raw['keep'];
    final folder = raw['folder'];
    return BackupSchedule(
      frequency: BackupFrequency.parse(raw['frequency']),
      keep: keep is int ? keep.clamp(minKeep, maxKeep) : defaultKeep,
      folder: folder is String && folder.trim().isNotEmpty
          ? folder.trim()
          : null,
    );
  }

  final BackupFrequency frequency;
  final int keep;
  final String? folder;

  Map<String, Object?> toJson() => {
    'frequency': frequency.name,
    'keep': keep,
    'folder': ?folder,
  };
}

/// The server's backups: made when asked, on the schedule, and restored.
/// Settings → Data reaches them through `ServerAdministration`.
class ServerBackups {
  ServerBackups({
    required this.dataDirectory,
    required this.database,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String dataDirectory;
  final AppDatabase database;
  final DateTime Function() _clock;
  Timer? _timer;
  Future<void>? _running;

  /// The last scheduled run's outcome, until the server restarts.
  Map<String, Object?>? _last;

  BackupSchedule get schedule {
    final raw = database.readMetadata(BackupSchedule.key);
    try {
      return BackupSchedule.fromJson(raw == null ? null : jsonDecode(raw));
    } on FormatException {
      return const BackupSchedule();
    }
  }

  /// Checks now and every [every] whether a scheduled backup is due.
  void start({Duration every = const Duration(hours: 1)}) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => runScheduled());
    unawaited(runScheduled());
  }

  void cancel() => _timer?.cancel();

  Future<BackupWritten> create(String folder) => writeBackup(
    dataDirectory: dataDirectory,
    outputDirectory: folder,
    now: _clock(),
  );

  /// Makes a backup when the schedule says one is due — the newest in its
  /// folder is older than its interval — then keeps the newest `keep`.
  /// Returns the backup's path, or null when none was due.
  Future<String?> runScheduled() async {
    if (_running != null) return null;
    final schedule = this.schedule;
    final every = schedule.frequency.every;
    final folder = schedule.folder;
    if (every == null || folder == null) return null;
    final done = Completer<void>();
    _running = done.future;
    try {
      final now = _clock();
      final newest = _backupsIn(folder).firstOrNull;
      if (newest != null && now.difference(newest.at) < every) return null;
      final written = await create(folder);
      final removed = prune(folder, keep: schedule.keep);
      _last = {
        'at': now.toUtc().toIso8601String(),
        'path': written.path,
        'removed': removed,
      };
      return written.path;
    } on Object catch (error) {
      _last = {'at': _clock().toUtc().toIso8601String(), 'error': '$error'};
      return null;
    } finally {
      _running = null;
      done.complete();
    }
  }

  /// Deletes all but the newest [keep] backups in [folder]; only files named
  /// as backups are ever touched.
  int prune(String folder, {required int keep}) {
    var removed = 0;
    for (final old in _backupsIn(folder).skip(keep)) {
      try {
        old.file.deleteSync();
        removed++;
      } on FileSystemException {
        // In use or already gone; the next run tries again.
      }
    }
    return removed;
  }

  Map<String, Object?> describe() {
    final schedule = this.schedule;
    final folder = schedule.folder;
    final newest = folder == null ? null : _backupsIn(folder).firstOrNull;
    return {
      ...schedule.toJson(),
      'newest': ?newest?.at.toIso8601String(),
      'last': ?_last,
      'lastRestore': ?lastRestore(dataDirectory),
      'pendingRestore': pendingRestore(dataDirectory) != null,
    };
  }

  Map<String, Object?> setSchedule(Map<String, Object?> arguments) {
    final next = BackupSchedule.fromJson(arguments);
    database.writeMetadata(BackupSchedule.key, jsonEncode(next.toJson()));
    if (next.frequency != BackupFrequency.off) unawaited(runScheduled());
    return describe();
  }

  /// The backups in [folder], newest first, by the time in their names.
  List<({File file, DateTime at})> _backupsIn(String folder) {
    final directory = Directory(folder);
    if (!directory.existsSync()) return const [];
    final found = <({File file, DateTime at})>[];
    for (final entry in directory.listSync(followLinks: false)) {
      if (entry is! File) continue;
      final at = backupFileTime(p.basename(entry.path));
      if (at != null) found.add((file: entry, at: at));
    }
    return found..sort((a, b) => b.at.compareTo(a.at));
  }
}
