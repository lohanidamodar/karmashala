import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'backup_manifest.dart';
import 'backup_writer.dart';

/// Inside the data directory: the restore waiting for the next start, and
/// the record of the last one done.
const String kPendingRestoreFile = 'restore.pending.json';
const String kLastRestoreFile = 'restore.last.json';

/// What [inspectBackup] read: the manifest, and why this server would refuse
/// it, or null.
typedef BackupInspection = ({BackupManifest manifest, String? refusal});

/// Reads [archive]'s manifest without unpacking the rest. Throws
/// [BackupRefused] for a file that is not a backup this build can read.
Future<BackupInspection> inspectBackup(
  String archive, {
  required int knownSchema,
}) => _withArchive(archive, (zip) async {
  final manifest = _manifestOf(zip);
  return (manifest: manifest, refusal: _refusal(manifest, knownSchema));
});

/// What [stageRestore] prepared.
typedef StagedRestore = ({String staged, int schemaFrom, int schemaTo});

/// Unpacks [archive] into a fresh folder beside [dataDirectory], checks every
/// file against the manifest, migrates its store to this build's schema and
/// checks it, then leaves a note for [applyPendingRestore] at the next start.
/// Nothing in [dataDirectory] is touched; a failure removes the fresh folder.
Future<StagedRestore> stageRestore(
  String archive, {
  required String dataDirectory,
  DateTime? now,
}) async {
  final known = AppDatabase.memory();
  final knownSchema = known.schemaVersion;
  known.close();
  final staged = Directory(
    '${p.normalize(dataDirectory)}.restore-${_stamp(now ?? DateTime.now())}',
  );
  if (staged.existsSync()) {
    throw BackupRefused('${staged.path} already exists; remove it first');
  }
  return _withArchive(archive, (zip) async {
    final manifest = _manifestOf(zip);
    final refusal = _refusal(manifest, knownSchema);
    if (refusal != null) throw BackupRefused(refusal);
    staged.createSync(recursive: true);
    try {
      final expected = {
        kSnapshotEntry: manifest.database,
        for (final file in manifest.files) '$kFilesPrefix${file.path}': file,
      };
      for (final entry in zip.files) {
        if (!entry.isFile || entry.name == kManifestEntry) continue;
        if (!expected.containsKey(entry.name)) {
          throw BackupRefused(
            'the backup holds ${entry.name}, which its manifest does not list',
          );
        }
      }
      for (final MapEntry(key: name, value: file) in expected.entries) {
        final entry = zip.findFile(name);
        if (entry == null) {
          throw BackupRefused('the backup is missing $name');
        }
        final relative = name == kSnapshotEntry ? kStoreFileName : file.path;
        final target = _inside(staged.path, relative);
        File(target).parent.createSync(recursive: true);
        final out = OutputFileStream(target);
        entry.writeContent(out);
        await out.close();
        final written = File(target);
        final digest = await crypto.sha256.bind(written.openRead()).first;
        if (written.lengthSync() != file.bytes || '$digest' != file.sha256) {
          throw BackupRefused('$name does not match the manifest: damaged');
        }
      }
      final schemaFrom = _userVersion(p.join(staged.path, kStoreFileName));
      if (schemaFrom != manifest.schemaVersion) {
        throw BackupRefused(
          'the store in the backup is at schema v$schemaFrom, not the '
          "manifest's v${manifest.schemaVersion}",
        );
      }
      final database = AppDatabase.open(staged, refuseNewerSchema: true);
      try {
        final check = database.query('PRAGMA integrity_check;');
        if (check.first.values.first != 'ok') {
          throw const BackupRefused("the backup's store fails its check");
        }
      } finally {
        database.close();
      }
      File(p.join(dataDirectory, kPendingRestoreFile)).writeAsStringSync(
        jsonEncode({
          'staged': staged.path,
          'archive': archive,
          'backupCreatedAt': manifest.createdAt.toIso8601String(),
          'schemaFrom': schemaFrom,
          'schemaTo': knownSchema,
        }),
      );
      return (
        staged: staged.path,
        schemaFrom: schemaFrom,
        schemaTo: knownSchema,
      );
    } catch (_) {
      if (staged.existsSync()) staged.deleteSync(recursive: true);
      rethrow;
    }
  });
}

/// The restore staged for the next start, as [kPendingRestoreFile] holds it.
Map<String, Object?>? pendingRestore(String dataDirectory) =>
    _readJson(p.join(dataDirectory, kPendingRestoreFile));

/// The last restore done here, as [kLastRestoreFile] holds it.
Map<String, Object?>? lastRestore(String dataDirectory) =>
    _readJson(p.join(dataDirectory, kLastRestoreFile));

/// Switches [dataDirectory] to a staged restore, before anything opens it:
/// the store and the backed-up folders move to
/// `<data>.before-restore-<time>`, the staged ones take their place, and
/// paired phones are carried over from the old store. What a backup never
/// holds — the vaults, `server.json`, logs — stays where it is. Returns a
/// line for the log, or null when nothing was pending.
String? applyPendingRestore(String dataDirectory, {DateTime? now}) {
  final marker = File(p.join(dataDirectory, kPendingRestoreFile));
  final pending = pendingRestore(dataDirectory);
  if (pending == null) {
    if (marker.existsSync()) marker.deleteSync();
    return null;
  }
  marker.deleteSync();
  final staged = Directory(pending['staged']! as String);
  if (!staged.existsSync()) {
    return 'restore skipped: ${staged.path} is gone';
  }
  final before = Directory(
    '${p.normalize(dataDirectory)}.before-restore-'
    '${_stamp(now ?? DateTime.now())}',
  )..createSync(recursive: true);
  final names = [...kStoreFiles, ...kBackedUpFolders];
  final movedOut = <String>[];
  final movedIn = <String>[];
  try {
    for (final name in names) {
      if (_move(p.join(dataDirectory, name), p.join(before.path, name))) {
        movedOut.add(name);
      }
    }
    for (final name in names) {
      if (_move(p.join(staged.path, name), p.join(dataDirectory, name))) {
        movedIn.add(name);
      }
    }
  } on FileSystemException catch (error) {
    for (final name in movedIn) {
      _move(p.join(dataDirectory, name), p.join(staged.path, name));
    }
    for (final name in movedOut) {
      _move(p.join(before.path, name), p.join(dataDirectory, name));
    }
    return 'restore undone, the data is as it was: ${error.message} '
        '(${error.path})';
  }
  staged.deleteSync(recursive: true);
  final phones = _carryPairedDevices(
    p.join(dataDirectory, kStoreFileName),
    p.join(before.path, kStoreFileName),
  );
  File(p.join(dataDirectory, kLastRestoreFile)).writeAsStringSync(
    jsonEncode({
      ...pending,
      'restoredAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'before': before.path,
      'phonesKept': phones,
    }),
  );
  return 'restored the backup of ${pending['backupCreatedAt']}; the data it '
      'replaced is in ${before.path}';
}

/// The pairings the replaced store held, so a restore does not unpair every
/// phone; null when they could not be read.
int? _carryPairedDevices(String store, String old) {
  if (!File(old).existsSync()) return 0;
  final db = sqlite3.open(store);
  try {
    db.execute('ATTACH DATABASE ? AS old;', [old]);
    Set<String> columns(String schema) => {
      for (final row in db.select('PRAGMA $schema.table_info(paired_devices);'))
        row['name']! as String,
    };
    final shared = columns('main').intersection(columns('old'));
    if (shared.isEmpty) return 0;
    final list = shared.map((name) => '"$name"').join(', ');
    db.execute(
      'INSERT OR IGNORE INTO main.paired_devices ($list) '
      'SELECT $list FROM old.paired_devices;',
    );
    return db.updatedRows;
  } on SqliteException {
    return null;
  } finally {
    db.close();
  }
}

bool _move(String from, String to) {
  final type = FileSystemEntity.typeSync(from, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  if (type == FileSystemEntityType.directory) {
    Directory(from).renameSync(to);
  } else {
    File(from).renameSync(to);
  }
  return true;
}

String? _refusal(BackupManifest manifest, int knownSchema) {
  if (manifest.schemaVersion > knownSchema) {
    return 'This backup is from a newer Karmashala (${manifest.appVersion}, '
        'schema v${manifest.schemaVersion}); this server knows schema '
        'v$knownSchema. Update Karmashala, then restore it.';
  }
  return null;
}

BackupManifest _manifestOf(Archive zip) {
  final entry = zip.findFile(kManifestEntry);
  final bytes = entry?.readBytes();
  if (bytes == null) {
    throw const BackupRefused('this is not a Karmashala backup: no manifest');
  }
  try {
    return BackupManifest.decode(bytes);
  } on FormatException catch (error) {
    throw BackupRefused(error.message);
  }
}

Future<T> _withArchive<T>(
  String archive,
  Future<T> Function(Archive zip) read,
) async {
  if (!File(archive).existsSync()) {
    throw BackupRefused('there is no file at $archive');
  }
  final input = InputFileStream(archive);
  try {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeStream(input);
    } on Object {
      throw const BackupRefused('this is not a Karmashala backup: not a zip');
    }
    return await read(zip);
  } finally {
    await input.close();
  }
}

/// [relative] under [root], refused when it would land outside it.
String _inside(String root, String relative) {
  final target = p.normalize(p.join(root, relative));
  if (p.isAbsolute(relative) || !p.isWithin(root, target)) {
    throw BackupRefused(
      'the backup names a path outside its folder: $relative',
    );
  }
  return target;
}

int _userVersion(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return db.select('PRAGMA user_version;').first.values.first! as int;
  } finally {
    db.close();
  }
}

Map<String, Object?>? _readJson(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String _stamp(DateTime at) => backupFileName(
  at,
).substring(kBackupFilePrefix.length).replaceAll(kBackupFileSuffix, '');
