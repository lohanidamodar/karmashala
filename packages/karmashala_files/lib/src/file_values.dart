/// The values a file pane, an editor and Quick Open carry: an entry, what a
/// stat saw, the version a save expects. Each has its JSON, because the
/// server answers them to clients (slice 3c).
library;

import 'package:agent_cli/process.dart';

/// What one entry in a listing is.
enum FileEntryKind {
  file,
  directory,
  symlink,
  other;

  static FileEntryKind fromName(Object? name) => FileEntryKind.values
      .firstWhere((kind) => kind.name == name, orElse: () => other);
}

/// One entry in a directory.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.sizeBytes,
    this.modifiedAt,
  });

  final String name;
  final EnvironmentPath path;
  final FileEntryKind kind;

  /// Null when the filesystem did not say — never 0 as a stand-in.
  final int? sizeBytes;
  final DateTime? modifiedAt;

  bool get isDirectory => kind == FileEntryKind.directory;

  /// A leading dot: what a browser hides by default.
  bool get isHidden => name.startsWith('.');

  Map<String, Object?> toJson() => {
    'name': name,
    'environmentId': path.environmentId,
    'path': path.path,
    'kind': kind.name,
    'size': ?sizeBytes,
    'modified': ?modifiedAt?.toUtc().toIso8601String(),
  };

  static FileEntry fromJson(Map<String, Object?> json) => FileEntry(
    name: json['name']! as String,
    path: EnvironmentPath(
      environmentId: json['environmentId']! as String,
      path: json['path']! as String,
    ),
    kind: FileEntryKind.fromName(json['kind']),
    sizeBytes: json['size'] as int?,
    modifiedAt: _time(json['modified']),
  );

  @override
  bool operator ==(Object other) =>
      other is FileEntry &&
      other.name == name &&
      other.path == path &&
      other.kind == kind &&
      other.sizeBytes == sizeBytes &&
      other.modifiedAt == modifiedAt;

  @override
  int get hashCode => Object.hash(name, path, kind, sizeBytes, modifiedAt);

  @override
  String toString() => 'FileEntry($name, ${kind.name})';
}

/// What a file looked like when it was read — what a save checks before it
/// overwrites. Null [modified] means the filesystem did not say.
class FileStamp {
  const FileStamp({required this.length, required this.modified});

  final int length;
  final DateTime? modified;

  /// Whether [other] is the same file we read. A missing modification time is
  /// not evidence of a change, so length decides alone.
  bool matches(FileStamp? other) {
    if (other == null) return false;
    if (other.length != length) return false;
    final mine = modified;
    final theirs = other.modified;
    if (mine == null || theirs == null) return true;
    return mine.isAtSameMomentAs(theirs);
  }

  Map<String, Object?> toJson() => {
    'length': length,
    'modified': ?modified?.toUtc().toIso8601String(),
  };

  static FileStamp fromJson(Map<String, Object?> json) => FileStamp(
    length: json['length']! as int,
    modified: _time(json['modified']),
  );

  @override
  bool operator ==(Object other) =>
      other is FileStamp &&
      other.length == length &&
      (other.modified == null) == (modified == null) &&
      (modified == null || other.modified!.isAtSameMomentAs(modified!));

  @override
  int get hashCode => Object.hash(length, modified?.microsecondsSinceEpoch);

  @override
  String toString() => 'FileStamp($length, $modified)';
}

/// What one stat saw; [stamp] is null exactly when nothing is there.
class FileStat {
  const FileStat.absent() : exists = false, isDirectory = false, size = 0, stamp = null;

  const FileStat({
    required this.isDirectory,
    required this.size,
    required FileStamp this.stamp,
  }) : exists = true;

  final bool exists;
  final bool isDirectory;
  final int size;
  final FileStamp? stamp;

  Map<String, Object?> toJson() => exists
      ? {'directory': isDirectory, 'size': size, 'stamp': stamp!.toJson()}
      : const {'absent': true};

  static FileStat fromJson(Map<String, Object?> json) => json['absent'] == true
      ? const FileStat.absent()
      : FileStat(
          isDirectory: json['directory']! as bool,
          size: json['size']! as int,
          stamp: FileStamp.fromJson(
            (json['stamp']! as Map).cast<String, Object?>(),
          ),
        );
}

/// What a write expects to find, so it can refuse rather than overwrite a
/// change it has not seen.
sealed class WriteExpectation {
  const WriteExpectation();

  /// Overwrite whatever is there — the reader chose to.
  const factory WriteExpectation.any() = _Any;

  /// Nothing may be there: a deleted file put back by Save.
  const factory WriteExpectation.absent() = _Absent;

  /// The file must still be [version].
  const factory WriteExpectation.version(FileStamp version) = _Version;

  /// Whether a file currently at [current] (null: absent) may be replaced.
  bool accepts(FileStamp? current);

  Map<String, Object?> toJson();

  static WriteExpectation fromJson(Map<String, Object?> json) =>
      switch (json['expect']) {
        'absent' => const WriteExpectation.absent(),
        'version' => WriteExpectation.version(
          FileStamp.fromJson((json['stamp']! as Map).cast<String, Object?>()),
        ),
        _ => const WriteExpectation.any(),
      };
}

final class _Any extends WriteExpectation {
  const _Any();

  @override
  bool accepts(FileStamp? current) => true;

  @override
  Map<String, Object?> toJson() => const {'expect': 'any'};
}

final class _Absent extends WriteExpectation {
  const _Absent();

  @override
  bool accepts(FileStamp? current) => current == null;

  @override
  Map<String, Object?> toJson() => const {'expect': 'absent'};
}

final class _Version extends WriteExpectation {
  const _Version(this.version);

  final FileStamp version;

  @override
  bool accepts(FileStamp? current) => version.matches(current);

  @override
  Map<String, Object?> toJson() => {
    'expect': 'version',
    'stamp': version.toJson(),
  };
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// A name that cannot be a file: empty, a path of its own, or one of the two
/// directory entries every listing hides. Checked before the filesystem sees
/// it, because "create a folder called `../x`" is a surprise, not an error.
String? nameRefusal(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'A name is needed.';
  if (trimmed == '.' || trimmed == '..') return 'That name is taken.';
  if (trimmed.contains('/') || trimmed.contains(r'\')) {
    return 'A name cannot contain a path separator.';
  }
  return null;
}
