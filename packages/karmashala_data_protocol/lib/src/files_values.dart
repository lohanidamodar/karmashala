/// What the server's file requests answer beyond the values
/// `karmashala_files` carries (slice 3c).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_projects/karmashala_projects.dart'
    show environmentPathFromJson, environmentPathToJson;

/// A path made absolute at the server, and the same place as the server's
/// own process spells it for `dart:io` — a WSL file's `\\wsl.localhost`
/// form — or null where there is none (an SSH host).
class ResolvedPath {
  const ResolvedPath(this.path, {this.localPath});

  final EnvironmentPath path;
  final String? localPath;

  Map<String, Object?> toJson() => {
    'path': environmentPathToJson(path),
    'localPath': ?localPath,
  };

  static ResolvedPath fromJson(Map<String, Object?> json) => ResolvedPath(
    environmentPathFromJson(json['path']),
    localPath: json['localPath'] as String?,
  );
}

/// One chunk of a file: [bytes] from the offset asked for, and how long the
/// whole file is, so a reader knows when it has it all.
class FileChunk {
  const FileChunk(this.bytes, {required this.fileSize});

  final Uint8List bytes;
  final int fileSize;

  Map<String, Object?> toJson() => {
    'bytes': base64Encode(bytes),
    'size': fileSize,
  };

  static FileChunk fromJson(Map<String, Object?> json) => FileChunk(
    base64Decode(json['bytes']! as String),
    fileSize: json['size']! as int,
  );
}

/// A folder pinned to every file browser's quick-access column, on every
/// client of this server. [path] is spelled for its own environment, as every
/// stored path is; [label] replaces the folder's own name when set.
class QuickAccessPin {
  const QuickAccessPin({
    required this.environmentId,
    required this.path,
    this.label,
  });

  /// The most a server keeps: a column, not a bookmarks manager.
  static const int maxPins = 100;
  static const int maxLabelLength = 200;
  static const int maxPathLength = 4096;

  final String environmentId;
  final String path;
  final String? label;

  /// Whether [other] names the same folder; see [quickAccessFolderKey].
  bool sameFolder(QuickAccessPin other) =>
      other.environmentId == environmentId &&
      quickAccessFolderKey(other.path) == quickAccessFolderKey(path);

  QuickAccessPin withLabel(String? label) =>
      QuickAccessPin(environmentId: environmentId, path: path, label: label);

  Map<String, Object?> toJson() => {
    'environmentId': environmentId,
    'path': path,
    'label': ?label,
  };

  static QuickAccessPin fromJson(Map<String, Object?> json) => QuickAccessPin(
    environmentId: json['environmentId']! as String,
    path: json['path']! as String,
    label: json['label'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is QuickAccessPin &&
      other.environmentId == environmentId &&
      other.path == path &&
      other.label == label;

  @override
  int get hashCode => Object.hash(environmentId, path, label);
}

/// [path] as two spellings of one folder agree on: a Windows spelling folds
/// case and separators, a POSIX one does not, and a trailing separator never
/// counts.
String quickAccessFolderKey(String path) {
  final windows = RegExp(r'^[A-Za-z]:|\\').hasMatch(path);
  var key = windows ? path.replaceAll(r'\', '/').toLowerCase() : path;
  while (key.length > 1 && key.endsWith('/') && !key.endsWith(':/')) {
    key = key.substring(0, key.length - 1);
  }
  return key;
}
