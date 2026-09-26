import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:path/path.dart' as p;

import '../domain/document_source.dart';
import '../domain/source_document.dart';

var _tempCounter = 0;

/// A host's files over SFTP. The save is a temp file, the original's mode put
/// on it, a last version check, and `posix-rename@openssh.com` over the
/// target; where any of that cannot keep the file what it was — a symlink, a
/// server without the extension, an owner we are not — it is written in place
/// instead, still checked first.
class SftpDocumentSource implements DocumentSource {
  SftpDocumentSource(this.files, {this.onClose});

  final RemoteDocumentFiles files;

  /// Releases what the source holds open; the connection is not its to close.
  final Future<void> Function()? onClose;

  @override
  String get environmentId => files.environmentId;

  /// Remote paths are POSIX whatever this desktop runs.
  @override
  p.Context get pathContext => p.posix;

  @override
  DocumentSourceCapabilities get capabilities =>
      const DocumentSourceCapabilities(atomicReplace: true, cheapStat: false);

  @override
  String? hostPathOf(String path) => null;

  EnvironmentPath _at(String path) =>
      EnvironmentPath(environmentId: environmentId, path: path);

  @override
  Future<DocumentStat> stat(String path) =>
      _guard(() async => _statOf(await files.statFile(_at(path))));

  static DocumentStat _statOf(RemoteFileStat? stat) => stat == null
      ? const DocumentStat.absent()
      : DocumentStat(
          isDirectory: stat.isDirectory,
          size: stat.size,
          version: _stampOf(stat)!,
        );

  static FileStamp? _stampOf(RemoteFileStat? stat) => stat == null
      ? null
      : FileStamp(length: stat.size, modified: stat.modifiedAt);

  @override
  Future<Uint8List> read(String path, {int? length}) =>
      _guard(() => files.readBytes(_at(path), length: length));

  @override
  Future<FileStamp> write(
    String path,
    Uint8List bytes, {
    required WriteExpectation expect,
  }) => _guard(() async {
    final target = _at(path);
    final before = await files.statFile(target);
    if (before != null && before.isDirectory) {
      throw DocumentSourceException('$path is a folder, not a file.');
    }
    if (!expect.accepts(_stampOf(before))) {
      throw DocumentStaleException(_stampOf(before));
    }
    if (before == null) {
      await _create(target, bytes);
    } else if (await files.isSymlink(target) ||
        !await files.replacesAtomically()) {
      await files.overwriteFile(target, bytes);
    } else {
      await _replace(target, before, bytes, expect);
    }
    final after = _stampOf(await files.statFile(target));
    if (after == null) {
      throw DocumentSourceException(
        'it was written and then could not be found at $path.',
      );
    }
    return after;
  });

  /// "Save" on a deleted file puts it back — but never makes the folder it was
  /// in, and never over something that appeared meanwhile.
  Future<void> _create(EnvironmentPath target, Uint8List bytes) async {
    final parent = p.posix.dirname(target.path);
    final folder = await files.statFile(_at(parent));
    if (folder == null || !folder.isDirectory) {
      throw DocumentSourceException('$parent does not exist.');
    }
    try {
      await files.writeNewFile(target, bytes);
    } on RemoteUnreachableException {
      rethrow;
    } on RemoteBrowseException {
      final now = await files.statFile(target);
      if (now != null) throw DocumentStaleException(_stampOf(now));
      rethrow;
    }
  }

  Future<void> _replace(
    EnvironmentPath target,
    RemoteFileStat before,
    Uint8List bytes,
    WriteExpectation expect,
  ) async {
    final temp = _at(
      p.posix.join(
        p.posix.dirname(target.path),
        '.${p.posix.basename(target.path)}.karmashala-'
        '${DateTime.now().microsecondsSinceEpoch}-${_tempCounter++}.tmp',
      ),
    );
    try {
      await files.writeNewFile(temp, bytes);
    } on RemoteUnreachableException {
      rethrow;
    } on RemoteBrowseException {
      // A folder we may not create in can still hold a file we may write.
      await files.overwriteFile(target, bytes);
      return;
    }
    try {
      final made = await files.statFile(temp);
      if (!_sameOwner(before, made)) {
        await _removeQuietly(temp);
        await files.overwriteFile(target, bytes);
        return;
      }
      final permissions = before.permissions;
      if (permissions != null) await files.setPermissions(temp, permissions);
      final now = await files.statFile(target);
      if (!expect.accepts(_stampOf(now))) {
        throw DocumentStaleException(_stampOf(now));
      }
      await files.replace(temp, target);
    } on Object {
      await _removeQuietly(temp);
      rethrow;
    }
  }

  /// Unknown on either side is not a reason to refuse the atomic path: a
  /// server that reports no owner reports none for both.
  static bool _sameOwner(RemoteFileStat before, RemoteFileStat? made) {
    if (made == null) return false;
    if (before.userId != null &&
        made.userId != null &&
        before.userId != made.userId) {
      return false;
    }
    if (before.groupId != null &&
        made.groupId != null &&
        before.groupId != made.groupId) {
      return false;
    }
    return true;
  }

  Future<void> _removeQuietly(EnvironmentPath path) async {
    try {
      await files.removeFile(path);
    } on Object {
      // A temp file left behind is untidy, not a lost save.
    }
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RemoteUnreachableException catch (error) {
      throw DocumentUnreachableException(error.message);
    } on RemoteBrowseException catch (error) {
      throw DocumentSourceException(error.message);
    }
  }

  @override
  Future<void> close() async => onClose?.call();
}
