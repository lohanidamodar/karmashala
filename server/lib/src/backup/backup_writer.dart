import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:karmashala_checkpoints/checkpoints.dart' show Checkpoint;
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_store/database.dart' show kStoreFileName;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'backup_manifest.dart';

/// The name every backup archive gets, so the schedule can find its own and
/// prune them without touching anything else in the folder.
const String kBackupFilePrefix = 'karmashala-backup-';
const String kBackupFileSuffix = '.zip';

/// `karmashala-backup-20261009-153012.zip`, by [at] in UTC.
String backupFileName(DateTime at) {
  final u = at.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '$kBackupFilePrefix${u.year}${two(u.month)}${two(u.day)}-'
      '${two(u.hour)}${two(u.minute)}${two(u.second)}$kBackupFileSuffix';
}

/// When the backup named [name] was taken, or null for a name that is not
/// one of [backupFileName]'s.
DateTime? backupFileTime(String name) {
  final match = RegExp(
    '^${RegExp.escape(kBackupFilePrefix)}'
    r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})'
    '${RegExp.escape(kBackupFileSuffix)}\$',
  ).firstMatch(name);
  if (match == null) return null;
  final n = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  return DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5]);
}

/// What [writeBackup] wrote.
typedef BackupWritten = ({String path, BackupManifest manifest});

/// Writes one backup of [dataDirectory] into [outputDirectory]: a consistent
/// snapshot of the store taken with `VACUUM INTO` on its own connection in
/// another isolate, so the server keeps writing meanwhile, with the pairing
/// keys scrubbed from it; the files of [kBackedUpFolders] less any that look
/// like secrets; and a manifest saying what is in it and what is not.
Future<BackupWritten> writeBackup({
  required String dataDirectory,
  required String outputDirectory,
  DateTime? now,
}) async {
  final at = (now ?? DateTime.now()).toUtc();
  final output = Directory(outputDirectory);
  if (!output.existsSync()) output.createSync(recursive: true);
  if (p.isWithin(dataDirectory, outputDirectory) ||
      p.equals(dataDirectory, outputDirectory)) {
    throw const BackupRefused(
      "choose a folder outside Karmashala's data folder",
    );
  }
  final source = p.join(dataDirectory, kStoreFileName);
  if (!File(source).existsSync()) {
    throw BackupRefused('there is no store in $dataDirectory to back up');
  }
  final work = Directory.systemTemp.createTempSync('karmashala-backup-');
  final target = p.join(outputDirectory, backupFileName(at));
  final partial = '$target.partial';
  try {
    final snapshot = p.join(work.path, kStoreFileName);
    final read = await Isolate.run(() => _snapshot(source, snapshot));
    final database = await _describe(File(snapshot), kSnapshotEntry);

    final files = <BackupFile>[];
    final skipped = <String>[];
    final sources = <String, File>{};
    for (final folder in kBackedUpFolders) {
      final directory = Directory(p.join(dataDirectory, folder));
      if (!directory.existsSync()) continue;
      final entries =
          directory
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in entries) {
        final relative = p
            .relative(file.path, from: dataDirectory)
            .replaceAll(r'\', '/');
        if (looksLikeSecret(p.basename(file.path))) {
          skipped.add(relative);
          continue;
        }
        try {
          files.add(await _describe(file, relative));
          sources[relative] = file;
        } on FileSystemException {
          // Removed or locked between the listing and the read; a backup of
          // a live folder can only promise what it could read.
          skipped.add(relative);
        }
      }
    }

    files.sort((a, b) => a.path.compareTo(b.path));
    skipped.sort();
    final manifest = BackupManifest(
      appVersion: kHostVersion,
      schemaVersion: read.schemaVersion,
      createdAt: at,
      dataDirectory: dataDirectory,
      counts: read.counts,
      database: database,
      files: files,
      checkpoints: read.checkpoints,
      excluded: kBackupExclusions,
      notCarried: kBackupNotCarried,
      skipped: skipped,
    );

    final zip = ZipFileEncoder()..create(partial);
    try {
      zip.addArchiveFile(
        ArchiveFile.string(
          kManifestEntry,
          const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
        ),
      );
      await zip.addFile(File(snapshot), kSnapshotEntry);
      for (final file in files) {
        await zip.addFile(sources[file.path]!, '$kFilesPrefix${file.path}');
      }
    } finally {
      await zip.close();
    }
    File(partial).renameSync(target);
    return (path: target, manifest: manifest);
  } catch (_) {
    final left = File(partial);
    if (left.existsSync()) left.deleteSync();
    rethrow;
  } finally {
    work.deleteSync(recursive: true);
  }
}

/// A backup or restore this server will not do, in words for the person.
class BackupRefused implements Exception {
  const BackupRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<BackupFile> _describe(File file, String path) async {
  final digest = await crypto.sha256.bind(file.openRead()).first;
  return BackupFile(path: path, bytes: file.lengthSync(), sha256: '$digest');
}

typedef _SnapshotRead = ({
  int schemaVersion,
  Map<String, int> counts,
  List<BackupCheckpointRef> checkpoints,
});

/// `VACUUM INTO` reads one transaction's view of the store, WAL included, so
/// the copy is consistent however the server writes meanwhile. The copy is
/// then made a single file and its pairing keys are deleted with
/// `secure_delete`, so their bytes do not linger in free pages.
_SnapshotRead _snapshot(String source, String target) {
  final live = sqlite3.open(source);
  try {
    live.execute('PRAGMA busy_timeout = 5000;');
    live.execute('VACUUM INTO ?;', [target]);
  } finally {
    live.close();
  }
  final copy = sqlite3.open(target);
  try {
    copy.execute('PRAGMA journal_mode = DELETE;');
    copy.execute('PRAGMA secure_delete = ON;');
    if (_tableExists(copy, 'paired_devices')) {
      copy.execute('DELETE FROM paired_devices;');
    }
    final tables = copy
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' ORDER BY name;",
        )
        .map((row) => row['name']! as String);
    final counts = {
      for (final table in tables)
        table:
            copy.select('SELECT COUNT(*) AS n FROM "$table";').first['n']!
                as int,
    };
    final checkpoints = _tableExists(copy, 'session_checkpoints')
        ? [
            for (final row in copy.select(
              'SELECT environment_id, repository_path, session_id, '
              'COUNT(*) AS n, MAX(sequence) AS newest, '
              '(SELECT commit_sha FROM session_checkpoints c2 '
              ' WHERE c2.session_id = c.session_id '
              ' AND c2.repository_path = c.repository_path '
              ' ORDER BY sequence DESC LIMIT 1) AS commit_sha '
              'FROM session_checkpoints c '
              'GROUP BY environment_id, repository_path, session_id '
              'ORDER BY repository_path, session_id;',
            ))
              BackupCheckpointRef(
                environmentId: row['environment_id']! as String,
                repositoryPath: row['repository_path']! as String,
                ref: Checkpoint.refFor(row['session_id']! as String),
                commitSha: row['commit_sha']! as String,
                checkpoints: row['n']! as int,
              ),
          ]
        : <BackupCheckpointRef>[];
    final version =
        copy.select('PRAGMA user_version;').first.values.first! as int;
    return (schemaVersion: version, counts: counts, checkpoints: checkpoints);
  } finally {
    copy.close();
  }
}

bool _tableExists(Database db, String table) => db.select(
  "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
  [table],
).isNotEmpty;
