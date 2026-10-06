import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';

/// A host's files kept in memory, so a test says exactly what is on disk.
class MemorySources implements ArtifactSources {
  final files = <EnvironmentPath, Uint8List>{};
  final modified = <EnvironmentPath, DateTime>{};
  final unreachable = <EnvironmentPath>{};
  var stats = 0;

  void put(String path, String text, {DateTime? at}) {
    final where = EnvironmentPath(environmentId: 'local', path: path);
    files[where] = Uint8List.fromList(utf8.encode(text));
    modified[where] = at ?? DateTime.utc(2026);
  }

  @override
  Future<ArtifactSourceStat> stat(EnvironmentPath path) async {
    stats++;
    if (unreachable.contains(path)) {
      throw const FileSystemException('host not reached');
    }
    final bytes = files[path];
    return bytes == null
        ? const ArtifactSourceStat.absent()
        : ArtifactSourceStat(size: bytes.length, modified: modified[path]);
  }

  @override
  Future<Uint8List> read(EnvironmentPath path) async {
    if (unreachable.contains(path)) {
      throw const FileSystemException('host not reached');
    }
    return files[path] ?? (throw FileSystemException('absent', path.path));
  }
}
