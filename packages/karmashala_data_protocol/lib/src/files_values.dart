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
