import 'package:dartssh2/dartssh2.dart';

import 'package:agent_cli/process.dart';
import '../domain/remote_directory_entry.dart';
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

/// Lists directories on a remote host over SFTP.
///
/// SFTP rather than `ls`: it returns structured entries with types and sizes
/// instead of text to be parsed, it rides the connection that is already open,
/// and it cannot be confused by a filename containing a newline.
class RemoteFileBrowser {
  RemoteFileBrowser({required this.connection, required this.environmentId});

  final SshConnection connection;

  /// The environment every returned path belongs to (`ssh:<hostId>`).
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

  /// Entries in [directory], directories first and then case-insensitively by
  /// name — the order a file browser wants, decided here so every caller agrees.
  ///
  /// Throws [ArgumentError] if [directory] belongs to another environment; a
  /// Windows path must never be sent to a remote server as though it were one
  /// of its own.
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
      throw RemoteBrowseException(
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
