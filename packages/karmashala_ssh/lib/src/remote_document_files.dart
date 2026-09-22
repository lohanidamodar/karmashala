import 'dart:typed_data';

import 'package:agent_cli/process.dart';

/// What a stat of one remote path saw.
class RemoteFileStat {
  const RemoteFileStat({
    required this.isDirectory,
    required this.size,
    this.modifiedAt,
    this.permissions,
    this.userId,
    this.groupId,
  });

  final bool isDirectory;
  final int size;

  /// The owner, when the server sent it: a file replaced by rename belongs to
  /// whoever wrote the replacement, which may not be who owned it.
  final int? userId;
  final int? groupId;

  /// Whole seconds: SFTP v3 carries no finer modification time.
  final DateTime? modifiedAt;

  /// The permission bits (`0777` plus set-id and sticky), when the server sent
  /// them.
  final int? permissions;
}

/// The SFTP verbs an editor's save is built from. An interface so the save's
/// own logic — the version check, the temp file, the rename, the mode — can be
/// exercised against an in-memory host.
abstract interface class RemoteDocumentFiles {
  String get environmentId;

  /// What is at [path], following links; null when nothing is.
  Future<RemoteFileStat?> statFile(EnvironmentPath path);

  /// Whether [path] is itself a symbolic link. A save writes through a link
  /// rather than replacing it with a file.
  Future<bool> isSymlink(EnvironmentPath path);

  /// The first [length] bytes of [path], or all of it.
  Future<Uint8List> readBytes(EnvironmentPath path, {int? length});

  /// Creates [path] holding [bytes]; refuses when something is already there.
  Future<void> writeNewFile(EnvironmentPath path, Uint8List bytes);

  /// Truncates [path] and writes [bytes] into it, keeping its inode, owner and
  /// mode — the in-place write.
  Future<void> overwriteFile(EnvironmentPath path, Uint8List bytes);

  Future<void> setPermissions(EnvironmentPath path, int permissions);

  /// Whether [replace] swaps a file in one step (`posix-rename@openssh.com`).
  Future<bool> replacesAtomically();

  /// Renames [from] over [to], replacing it.
  Future<void> replace(EnvironmentPath from, EnvironmentPath to);

  Future<void> removeFile(EnvironmentPath path);
}
