import 'dart:io' hide FileStat;
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:path/path.dart' as p;

import 'file_space.dart';
import 'file_values.dart';

var _tempCounter = 0;

/// A host's filesystem over SFTP, on the server's own pooled connection
/// (slice 3a) — so a key never leaves the server. The SFTP itself lives in
/// [RemoteFileBrowser]; this is the adapter, the wording and the save.
///
/// The save is a temp file, the original's mode put on it, a last version
/// check, and `posix-rename@openssh.com` over the target; where any of that
/// cannot keep the file what it was — a symlink, a server without the
/// extension, an owner we are not — it is written in place instead, still
/// checked first.
class SftpFileSpace extends FileSpace {
  SftpFileSpace({required this.files, required this.label})
    : browser = files is RemoteFileBrowser ? files : null;

  /// The document verbs a save is built from — the browser itself, or an
  /// in-memory host in a test.
  final RemoteDocumentFiles files;

  /// Listing, creating, renaming, deleting and copying; null only where a
  /// test gave [files] alone.
  final RemoteFileBrowser? browser;

  @override
  final String label;

  @override
  String get environmentId => files.environmentId;

  /// A remote path is POSIX whatever the server runs on — the backslash a
  /// Windows join produces is a character in a filename over there.
  @override
  p.Context get pathContext => p.posix;

  RemoteFileBrowser get _browser =>
      browser ?? (throw StateError('this space has no browser'));

  @override
  Future<EnvironmentPath> home() =>
      _guard('open your home folder', () => _browser.home());

  @override
  Future<EnvironmentPath> resolve(EnvironmentPath path) {
    requireOwnPath(path);
    return _guard('resolve ${path.path}', () => _browser.resolve(path));
  }

  @override
  Future<List<FileEntry>> list(
    EnvironmentPath directory, {
    bool details = true,
  }) async {
    requireOwnPath(directory);
    final entries = await _guard(
      'open ${directory.path}',
      () => _browser.list(directory),
    );
    return [
      for (final entry in entries)
        FileEntry(
          name: entry.name,
          path: entry.path,
          kind: switch (entry.kind) {
            RemoteEntryKind.directory => FileEntryKind.directory,
            RemoteEntryKind.file => FileEntryKind.file,
            RemoteEntryKind.symlink => FileEntryKind.symlink,
            RemoteEntryKind.other => FileEntryKind.other,
          },
          sizeBytes: entry.isDirectory ? null : entry.sizeBytes,
          modifiedAt: entry.modifiedAt?.toUtc(),
        ),
    ];
  }

  @override
  Future<FileStat> stat(EnvironmentPath path) {
    requireOwnPath(path);
    return _guard('read ${path.path}', () async {
      return _statOf(await files.statFile(path));
    });
  }

  static FileStat _statOf(RemoteFileStat? stat) => stat == null
      ? const FileStat.absent()
      : FileStat(
          isDirectory: stat.isDirectory,
          size: stat.size,
          stamp: _stampOf(stat)!,
        );

  static FileStamp? _stampOf(RemoteFileStat? stat) => stat == null
      ? null
      : FileStamp(length: stat.size, modified: stat.modifiedAt?.toUtc());

  @override
  Future<Uint8List> read(EnvironmentPath path, {int offset = 0, int? length}) {
    requireOwnPath(path);
    return _guard(
      'read ${path.path}',
      () => files.readBytes(path, offset: offset, length: length),
    );
  }

  @override
  Future<FileStamp> write(
    EnvironmentPath path,
    Uint8List bytes, {
    required WriteExpectation expect,
  }) {
    requireOwnPath(path);
    return _guard('write ${path.path}', () async {
      final before = await files.statFile(path);
      if (before != null && before.isDirectory) {
        throw FileSpaceException('${path.path} is a folder, not a file.');
      }
      if (!expect.accepts(_stampOf(before))) {
        throw FileStaleException(_stampOf(before));
      }
      if (before == null) {
        await _create(path, bytes);
      } else if (await files.isSymlink(path) ||
          !await files.replacesAtomically()) {
        await files.overwriteFile(path, bytes);
      } else {
        await _replace(path, before, bytes, expect);
      }
      final after = _stampOf(await files.statFile(path));
      if (after == null) {
        throw FileSpaceException(
          'it was written and then could not be found at ${path.path}.',
        );
      }
      return after;
    });
  }

  /// "Save" on a deleted file puts it back — but never makes the folder it was
  /// in, and never over something that appeared meanwhile.
  Future<void> _create(EnvironmentPath target, Uint8List bytes) async {
    final parent = p.posix.dirname(target.path);
    final folder = await files.statFile(_at(parent));
    if (folder == null || !folder.isDirectory) {
      throw FileSpaceException('$parent does not exist.');
    }
    try {
      await files.writeNewFile(target, bytes);
    } on RemoteUnreachableException {
      rethrow;
    } on RemoteBrowseException {
      final now = await files.statFile(target);
      if (now != null) throw FileStaleException(_stampOf(now));
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
        throw FileStaleException(_stampOf(now));
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

  @override
  Future<EnvironmentPath> createDirectory(
    EnvironmentPath parent,
    String name,
  ) async {
    final made = target(parent, name);
    await _guard('create "$name"', () => _browser.makeDirectory(made));
    return made;
  }

  @override
  Future<EnvironmentPath> createFile(
    EnvironmentPath parent,
    String name,
  ) async {
    final made = target(parent, name);
    await _guard('create "$name"', () => _browser.makeFile(made));
    return made;
  }

  @override
  Future<EnvironmentPath> rename(EnvironmentPath target, String name) async {
    final to = renamed(target, name);
    await _guard('rename to "$name"', () => _browser.rename(target, to));
    return to;
  }

  @override
  Future<void> delete(EnvironmentPath target, {bool recursive = false}) {
    requireOwnPath(target);
    return _guard(
      'delete ${pathContext.basename(target.path)}',
      () => _browser.remove(target, recursive: recursive),
    );
  }

  @override
  Future<void> copyToLocal(
    EnvironmentPath source,
    String destination, {
    void Function(int bytes)? onProgress,
  }) async {
    requireOwnPath(source);
    final sink = File(destination).openWrite();
    try {
      await _guard(
        'download ${pathContext.basename(source.path)}',
        () => _browser.readInto(source, sink, onProgress: onProgress),
      );
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> copyFromLocal(
    String source,
    EnvironmentPath destination, {
    void Function(int bytes)? onProgress,
  }) {
    requireOwnPath(destination);
    return _guard(
      'upload ${p.basename(source)}',
      () => _browser.writeFrom(
        destination,
        File(source).openRead(),
        onProgress: onProgress,
      ),
    );
  }

  /// Null, always: a file on a host is bytes over a wire, never a path the
  /// server's process can open.
  @override
  String? hostPathOf(EnvironmentPath path) => null;

  @override
  Future<void> close() async => browser?.close();

  EnvironmentPath _at(String path) =>
      EnvironmentPath(environmentId: environmentId, path: path);

  /// One wording for everything the host refuses: what was being done, and
  /// what it said — never a bare `SftpStatusError`. A dropped link is
  /// [FileUnreachableException], not the host saying no.
  Future<T> _guard<T>(String what, Future<T> Function() body) async {
    try {
      return await body();
    } on FileSpaceException {
      rethrow;
    } on RemoteUnreachableException catch (error) {
      throw FileUnreachableException(error.message, cause: error.cause);
    } on RemoteBrowseException catch (error) {
      throw FileSpaceException(error.message, cause: error.cause ?? error);
    } on FileSystemException catch (error) {
      // The local half of a transfer: the file being read or written here.
      throw FileSpaceException(
        'Cannot $what: ${error.osError?.message ?? error.message}',
        cause: error,
      );
    }
  }
}
