import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'package:agent_cli/process.dart';
import 'remote_directory_entry.dart';
import 'remote_document_files.dart';
import 'ssh_connection.dart';

/// Raised when a remote directory cannot be listed.
class RemoteBrowseException implements Exception {
  RemoteBrowseException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() =>
      'RemoteBrowseException: $message${cause == null ? '' : ' ($cause)'}';
}

/// The connection is down, so nothing was learned about the file — distinct
/// from the host refusing, which is an answer.
class RemoteUnreachableException extends RemoteBrowseException {
  RemoteUnreachableException(super.message, {super.cause});
}

/// Lists directories on a remote host over SFTP: structured entries rather than
/// parsed `ls`, on the connection that is already open.
class RemoteFileBrowser implements RemoteDocumentFiles {
  RemoteFileBrowser({required this.connection, required this.environmentId});

  final SshConnection connection;

  /// The environment every returned path belongs to (`ssh:<hostId>`).
  @override
  final String environmentId;

  SftpClient? _sftp;

  /// Resolves the remote home directory of the logged-in user.
  Future<EnvironmentPath> home() => _resolve('.');

  /// Resolves [path] against the remote working directory, returning an
  /// absolute remote path.
  Future<EnvironmentPath> resolve(EnvironmentPath path) {
    _requireOwnEnvironment(path);
    return _resolve(path.path);
  }

  /// Entries in [directory], directories first then case-insensitive by name.
  /// Throws [ArgumentError] if [directory] belongs to another environment.
  Future<List<RemoteDirectoryEntry>> list(EnvironmentPath directory) async {
    _requireOwnEnvironment(directory);
    final sftp = await _client();
    final List<SftpName> names;
    try {
      names = await sftp.listdir(directory.path);
    } on SftpError catch (e) {
      throw RemoteBrowseException(
        'Cannot list ${directory.path} on ${connection.host.address}',
        cause: e,
      );
    }

    final entries = <RemoteDirectoryEntry>[];
    for (final name in names) {
      if (name.filename == '.' || name.filename == '..') continue;
      entries.add(
        RemoteDirectoryEntry(
          name: name.filename,
          path: EnvironmentPath(
            environmentId: environmentId,
            path: joinRemotePath(directory.path, name.filename),
          ),
          kind: _kindOf(name.attr),
          sizeBytes: name.attr.size,
          modifiedAt: name.attr.modifyTime == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  name.attr.modifyTime! * 1000,
                  isUtc: true,
                ),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// What is at [path], or null when nothing is. A delete asks first: a
  /// directory removed as a file fails, and the reverse takes a tree.
  Future<RemoteEntryKind?> kindOf(EnvironmentPath path) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    try {
      return _kindOf(await sftp.stat(path.path, followLink: false));
    } on SftpError {
      return null;
    }
  }

  /// Creates the directory [path].
  Future<void> makeDirectory(EnvironmentPath path) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    await _run('create ${path.path}', () => sftp.mkdir(path.path));
  }

  /// Creates an empty file at [path]. Refuses when something is already there:
  /// opening for writing would otherwise truncate it without a word.
  Future<void> makeFile(EnvironmentPath path) async {
    _requireOwnEnvironment(path);
    if (await kindOf(path) != null) {
      throw RemoteBrowseException(
        'Something named ${_baseName(path.path)} is already there',
      );
    }
    final sftp = await _client();
    await _run('create ${path.path}', () async {
      final file = await sftp.open(
        path.path,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );
      await file.close();
    });
  }

  /// Renames [from] to [to] on the same host.
  Future<void> rename(EnvironmentPath from, EnvironmentPath to) async {
    _requireOwnEnvironment(from);
    _requireOwnEnvironment(to);
    final sftp = await _client();
    await _run('rename ${from.path}', () => sftp.rename(from.path, to.path));
  }

  /// Removes [path]. A directory needs [recursive], and its contents are
  /// removed depth first — SFTP has no "remove a tree".
  Future<void> remove(EnvironmentPath path, {bool recursive = false}) async {
    _requireOwnEnvironment(path);
    final kind = await kindOf(path);
    if (kind == null) {
      throw RemoteBrowseException('${path.path} is not there any more');
    }
    final sftp = await _client();
    if (kind != RemoteEntryKind.directory) {
      await _run('delete ${path.path}', () => sftp.remove(path.path));
      return;
    }
    if (recursive) {
      for (final entry in await list(path)) {
        await remove(entry.path, recursive: true);
      }
    }
    await _run('delete ${path.path}', () => sftp.rmdir(path.path));
  }

  /// Copies the remote file [path] into [sink], reporting the bytes moved.
  /// The caller owns [sink] and closes it.
  Future<void> readInto(
    EnvironmentPath path,
    Sink<List<int>> sink, {
    void Function(int bytes)? onProgress,
  }) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    await _run('read ${path.path}', () async {
      final file = await sftp.open(path.path);
      try {
        var moved = 0;
        await for (final chunk in file.read()) {
          sink.add(chunk);
          moved += chunk.length;
          onProgress?.call(moved);
        }
      } finally {
        await file.close();
      }
    });
  }

  /// Writes [chunks] to the remote file [path], replacing what is there.
  Future<void> writeFrom(
    EnvironmentPath path,
    Stream<List<int>> chunks, {
    void Function(int bytes)? onProgress,
  }) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    await _run('write ${path.path}', () async {
      final file = await sftp.open(
        path.path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        var moved = 0;
        await for (final chunk in chunks) {
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          await file.writeBytes(bytes, offset: moved);
          moved += bytes.length;
          onProgress?.call(moved);
        }
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<RemoteFileStat?> statFile(EnvironmentPath path) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    return _call('read ${path.path}', () async {
      final SftpFileAttrs attrs;
      try {
        attrs = await sftp.stat(path.path);
      } on SftpStatusError catch (error) {
        if (error.code == SftpStatusCode.noSuchFile) return null;
        rethrow;
      }
      final mtime = attrs.modifyTime;
      return RemoteFileStat(
        isDirectory: attrs.isDirectory,
        size: attrs.size ?? 0,
        modifiedAt: mtime == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true),
        permissions: attrs.mode == null ? null : attrs.mode!.value & 0xfff,
        userId: attrs.userID,
        groupId: attrs.groupID,
      );
    });
  }

  @override
  Future<bool> isSymlink(EnvironmentPath path) async =>
      await kindOf(path) == RemoteEntryKind.symlink;

  @override
  Future<Uint8List> readBytes(
    EnvironmentPath path, {
    int offset = 0,
    int? length,
  }) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    return _call('read ${path.path}', () async {
      final file = await sftp.open(path.path);
      try {
        return await file.readBytes(length: length, offset: offset);
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<void> writeNewFile(EnvironmentPath path, Uint8List bytes) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    await _call('write ${path.path}', () async {
      final file = await sftp.open(
        path.path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.exclusive |
            SftpFileOpenMode.write,
      );
      try {
        await file.writeBytes(bytes);
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<void> overwriteFile(EnvironmentPath path, Uint8List bytes) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    await _call('write ${path.path}', () async {
      final file = await sftp.open(
        path.path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        await file.writeBytes(bytes);
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<void> setPermissions(EnvironmentPath path, int permissions) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    await _call(
      'set the mode of ${path.path}',
      () => sftp.setStat(
        path.path,
        SftpFileAttrs(mode: SftpFileMode.value(permissions)),
      ),
    );
  }

  @override
  Future<bool> replacesAtomically() async {
    final sftp = await _client();
    final handshake = await sftp.handshake;
    return handshake.extensions['posix-rename@openssh.com'] == '1';
  }

  @override
  Future<void> replace(EnvironmentPath from, EnvironmentPath to) =>
      rename(from, to);

  @override
  Future<void> removeFile(EnvironmentPath path) async {
    _requireOwnEnvironment(path);
    final sftp = await _client();
    await _call('delete ${path.path}', () => sftp.remove(path.path));
  }

  /// Releases the SFTP channel. The SSH connection itself stays open.
  Future<void> close() async {
    final sftp = _sftp;
    _sftp = null;
    await sftp?.close();
  }

  Future<EnvironmentPath> _resolve(String path) async {
    final sftp = await _client();
    try {
      return EnvironmentPath(
        environmentId: environmentId,
        path: await sftp.absolute(path),
      );
    } on SftpError catch (e) {
      throw RemoteBrowseException(
        'Cannot resolve "$path" on ${connection.host.address}',
        cause: e,
      );
    }
  }

  /// Runs one SFTP call, turning the server's status into a sentence that
  /// names what was being done — `SftpStatusError(3)` alone says nothing.
  Future<void> _run(String what, Future<void> Function() body) =>
      _call(what, body);

  /// [_run] with a result. A channel that died under the call is
  /// [RemoteUnreachableException], not the host saying no.
  Future<T> _call<T>(String what, Future<T> Function() body) async {
    try {
      return await body();
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noConnection ||
          error.code == SftpStatusCode.connectionLost) {
        throw _unreachable(what, error);
      }
      throw RemoteBrowseException(
        'Cannot $what on ${connection.host.address}',
        cause: error,
      );
    } on SftpAbortError catch (error) {
      throw _unreachable(what, error);
    } on SftpError catch (error) {
      throw RemoteBrowseException(
        'Cannot $what on ${connection.host.address}',
        cause: error,
      );
    } on RemoteBrowseException {
      rethrow;
    } on Object catch (error) {
      if (!connection.isConnected) throw _unreachable(what, error);
      rethrow;
    }
  }

  RemoteUnreachableException _unreachable(String what, Object cause) =>
      RemoteUnreachableException(
        'Cannot $what: the connection to ${connection.host.address} was lost',
        cause: cause,
      );

  static String _baseName(String path) {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? path : path.substring(cut + 1);
  }

  Future<SftpClient> _client() async {
    final existing = _sftp;
    if (existing != null && connection.isConnected) return existing;
    // A reconnect invalidates the old channel, so the SFTP client is rebuilt
    // alongside it rather than being handed out dead.
    _sftp = null;
    try {
      final client = await connection.client();
      return _sftp = await client.sftp();
    } on SshConnectionException catch (e) {
      throw RemoteUnreachableException(
        'Cannot browse ${connection.host.address}: ${e.message}',
        cause: e.cause ?? e,
      );
    }
  }

  void _requireOwnEnvironment(EnvironmentPath path) {
    if (path.environmentId != environmentId) {
      throw ArgumentError(
        'Path ${path.path} belongs to environment "${path.environmentId}", '
        'not "$environmentId"; it cannot be browsed on '
        '${connection.host.address}.',
      );
    }
  }

  static RemoteEntryKind _kindOf(SftpFileAttrs attr) {
    if (attr.isDirectory) return RemoteEntryKind.directory;
    if (attr.isSymbolicLink) return RemoteEntryKind.symlink;
    if (attr.isFile) return RemoteEntryKind.file;
    return RemoteEntryKind.other;
  }
}
