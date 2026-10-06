import 'dart:typed_data';

import 'package:agent_cli/process.dart';

/// What a look at a source file found.
class ArtifactSourceStat {
  const ArtifactSourceStat({required this.size, this.modified})
    : exists = true;

  const ArtifactSourceStat.absent() : exists = false, size = 0, modified = null;

  final bool exists;
  final int size;
  final DateTime? modified;

  /// What a watcher compares between two looks.
  String get stamp =>
      exists ? '$size@${modified?.toUtc().toIso8601String()}' : 'absent';
}

/// Reads files on the host a session runs on — this machine, a WSL
/// distribution or an SSH box. A failure to reach the host throws; an absent
/// file is [ArtifactSourceStat.absent], so the two are never confused.
abstract interface class ArtifactSources {
  Future<ArtifactSourceStat> stat(EnvironmentPath path);

  Future<Uint8List> read(EnvironmentPath path);
}

/// Whether [path] is absolute in the spelling of its own host: POSIX, a
/// Windows drive, or a UNC share. A relative path names nothing a server can
/// find for certain, so it is refused rather than resolved against a guess.
bool isAbsoluteHostPath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// The last segment of [path], in either separator.
String hostBaseName(String path) {
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}
