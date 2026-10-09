import 'dart:convert';

/// The manifest's own format; a reader refuses one it does not know.
const String kBackupFormat = 'karmashala-backup';
const int kBackupFormatVersion = 1;

/// The archive's entry names.
const String kManifestEntry = 'manifest.json';
const String kSnapshotEntry = 'karmashala.sqlite';
const String kFilesPrefix = 'files/';

/// The data folders a backup carries, relative to the data directory:
/// attachments, uploads, artifacts with their visuals, verification
/// evidence, checkpoint screenshots, browser captures, media and recordings.
const List<String> kBackedUpFolders = [
  'attachments',
  'uploads',
  'artifacts',
  'verification',
  'checkpoint-screenshots',
  'captures',
  'media',
  'recordings',
];

/// The store files a restore replaces beside [kBackedUpFolders].
const List<String> kStoreFiles = [
  'karmashala.sqlite',
  'karmashala.sqlite-wal',
  'karmashala.sqlite-shm',
];

/// A file a backup never carries even inside a backed-up folder: what looks
/// like a secret by its name.
bool looksLikeSecret(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('.env') ||
      lower == 'key.properties' ||
      lower.startsWith('id_rsa') ||
      lower.startsWith('id_ed25519') ||
      lower.startsWith('id_ecdsa') ||
      const [
        '.jks',
        '.keystore',
        '.p12',
        '.pfx',
        '.pem',
        '.key',
        '.p8',
      ].any(lower.endsWith);
}

/// One file in the archive: its path under the data directory, size and
/// SHA-256, checked again on restore.
class BackupFile {
  const BackupFile({
    required this.path,
    required this.bytes,
    required this.sha256,
  });

  factory BackupFile.fromJson(Map<String, Object?> json) => BackupFile(
    path: json['path']! as String,
    bytes: json['bytes']! as int,
    sha256: json['sha256']! as String,
  );

  final String path;
  final int bytes;
  final String sha256;

  Map<String, Object?> toJson() => {
    'path': path,
    'bytes': bytes,
    'sha256': sha256,
  };
}

/// A checkpoint ref a backup depends on: the git objects stay in
/// [repositoryPath], so a restore on a machine without that repository has
/// the index rows but not the content.
class BackupCheckpointRef {
  const BackupCheckpointRef({
    required this.environmentId,
    required this.repositoryPath,
    required this.ref,
    required this.commitSha,
    required this.checkpoints,
  });

  factory BackupCheckpointRef.fromJson(Map<String, Object?> json) =>
      BackupCheckpointRef(
        environmentId: json['environmentId']! as String,
        repositoryPath: json['repositoryPath']! as String,
        ref: json['ref']! as String,
        commitSha: json['commitSha']! as String,
        checkpoints: json['checkpoints']! as int,
      );

  final String environmentId;
  final String repositoryPath;
  final String ref;

  /// The newest checkpoint's commit on [ref].
  final String commitSha;
  final int checkpoints;

  Map<String, Object?> toJson() => {
    'environmentId': environmentId,
    'repositoryPath': repositoryPath,
    'ref': ref,
    'commitSha': commitSha,
    'checkpoints': checkpoints,
  };
}

/// What a backup holds, written first into the archive as `manifest.json`.
class BackupManifest {
  const BackupManifest({
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.dataDirectory,
    required this.counts,
    required this.database,
    required this.files,
    required this.checkpoints,
    required this.excluded,
    required this.notCarried,
    required this.skipped,
  });

  /// Throws [FormatException] for anything that is not a manifest this build
  /// can read.
  factory BackupManifest.fromJson(Object? decoded) {
    if (decoded is! Map<String, Object?> ||
        decoded['format'] != kBackupFormat) {
      throw const FormatException('this is not a Karmashala backup');
    }
    final version = decoded['formatVersion'];
    if (version is! int || version > kBackupFormatVersion) {
      throw FormatException(
        'this backup is in format $version; this Karmashala reads format '
        '$kBackupFormatVersion — update Karmashala, then restore it',
      );
    }
    try {
      return BackupManifest(
        appVersion: decoded['appVersion']! as String,
        schemaVersion: decoded['schemaVersion']! as int,
        createdAt: DateTime.parse(decoded['createdAt']! as String),
        dataDirectory: decoded['dataDirectory']! as String,
        counts: {
          for (final entry
              in (decoded['counts']! as Map<String, Object?>).entries)
            entry.key: entry.value! as int,
        },
        database: BackupFile.fromJson(
          decoded['database']! as Map<String, Object?>,
        ),
        files: [
          for (final file in decoded['files']! as List<Object?>)
            BackupFile.fromJson(file! as Map<String, Object?>),
        ],
        checkpoints: [
          for (final ref in decoded['checkpoints']! as List<Object?>)
            BackupCheckpointRef.fromJson(ref! as Map<String, Object?>),
        ],
        excluded: (decoded['excluded']! as List<Object?>).cast<String>(),
        notCarried: (decoded['notCarried']! as List<Object?>).cast<String>(),
        skipped: (decoded['skipped']! as List<Object?>).cast<String>(),
      );
    } on TypeError {
      throw const FormatException('the backup manifest is damaged');
    }
  }

  static BackupManifest decode(List<int> bytes) =>
      BackupManifest.fromJson(jsonDecode(utf8.decode(bytes)));

  final String appVersion;
  final int schemaVersion;
  final DateTime createdAt;

  /// Where the data lived when it was backed up, so paths recorded in it can
  /// be read as that machine's.
  final String dataDirectory;

  /// Rows per table in the snapshot.
  final Map<String, int> counts;
  final BackupFile database;
  final List<BackupFile> files;
  final List<BackupCheckpointRef> checkpoints;

  /// What was left out by rule, and what is referred to but not carried.
  final List<String> excluded;
  final List<String> notCarried;

  /// Files inside backed-up folders left out because they look like secrets.
  final List<String> skipped;

  int get fileBytes => files.fold(0, (sum, file) => sum + file.bytes);

  Map<String, Object?> toJson() => {
    'format': kBackupFormat,
    'formatVersion': kBackupFormatVersion,
    'appVersion': appVersion,
    'schemaVersion': schemaVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'dataDirectory': dataDirectory,
    'counts': counts,
    'database': database.toJson(),
    'files': [for (final file in files) file.toJson()],
    'checkpoints': [for (final ref in checkpoints) ref.toJson()],
    'excluded': excluded,
    'notCarried': notCarried,
    'skipped': skipped,
  };

  /// The manifest as Settings shows it: everything but the per-file list,
  /// which can run to thousands of rows.
  Map<String, Object?> summaryJson() => {
    ...toJson()..remove('files'),
    'fileCount': files.length,
    'fileBytes': fileBytes,
  };
}
