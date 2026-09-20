import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:path/path.dart' as p;

import '../domain/file_space.dart';

/// A host's filesystem over SFTP as a [FileSpace], so the browser draws it with
/// the same widget it draws this machine with. All the SFTP itself lives in
/// [RemoteFileBrowser]; this is the adapter and the wording.
class SftpFileSpace extends FileSpace {
  SftpFileSpace({required this.browser, required this.label});

  final RemoteFileBrowser browser;

  @override
  final String label;

  @override
  String get environmentId => browser.environmentId;

  /// A remote path is POSIX whatever this desktop runs on — the backslash a
  /// Windows join produces is a character in a filename over there.
  @override
  p.Context get pathContext => p.posix;

  @override
  Future<EnvironmentPath> home() =>
      _guard('open your home folder', browser.home);

  @override
  Future<EnvironmentPath> resolve(EnvironmentPath path) {
    requireOwnPath(path);
    return _guard('resolve ${path.path}', () => browser.resolve(path));
  }

  @override
  Future<List<FileEntry>> list(EnvironmentPath directory) async {
    requireOwnPath(directory);
    final entries = await _guard(
      'open ${directory.path}',
      () => browser.list(directory),
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
          modifiedAt: entry.modifiedAt,
        ),
    ];
  }

  @override
  Future<EnvironmentPath> createDirectory(
    EnvironmentPath parent,
    String name,
  ) async {
    final target = _target(parent, name);
    await _guard('create "$name"', () => browser.makeDirectory(target));
    return target;
  }

  @override
  Future<EnvironmentPath> createFile(
    EnvironmentPath parent,
    String name,
  ) async {
    final target = _target(parent, name);
    await _guard('create "$name"', () => browser.makeFile(target));
    return target;
  }

  @override
  Future<EnvironmentPath> rename(EnvironmentPath target, String name) async {
    requireOwnPath(target);
    final refusal = nameRefusal(name);
    if (refusal != null) throw FileSpaceException(refusal);
    final parent = parentOf(target);
    if (parent == null) {
      throw const FileSpaceException('A root cannot be renamed.');
    }
    final renamed = child(parent, name.trim());
    await _guard('rename to "$name"', () => browser.rename(target, renamed));
    return renamed;
  }

  @override
  Future<void> delete(EnvironmentPath target, {bool recursive = false}) {
    requireOwnPath(target);
    return _guard(
      'delete ${pathContext.basename(target.path)}',
      () => browser.remove(target, recursive: recursive),
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
        () => browser.readInto(source, sink, onProgress: onProgress),
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
      () => browser.writeFrom(
        destination,
        File(source).openRead(),
        onProgress: onProgress,
      ),
    );
  }

  /// Null, always: a file on a host is bytes over a wire, never a path this
  /// process can open.
  @override
  String? hostPathOf(EnvironmentPath path) => null;

  @override
  Future<void> close() => browser.close();

  EnvironmentPath _target(EnvironmentPath parent, String name) {
    requireOwnPath(parent);
    final refusal = nameRefusal(name);
    if (refusal != null) throw FileSpaceException(refusal);
    return child(parent, name.trim());
  }

  /// One wording for everything the host refuses: what was being done, and
  /// what it said — never a bare `SftpStatusError`.
  Future<T> _guard<T>(String what, Future<T> Function() body) async {
    try {
      return await body();
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
