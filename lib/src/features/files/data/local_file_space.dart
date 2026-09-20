import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import '../domain/file_space.dart';

/// How a path in a space is spelled to `dart:io`, when the two differ. A WSL
/// distribution's files are read over `\\wsl.localhost`, but a path there is
/// stored, shown and handed to an agent in its POSIX spelling — so the bridge
/// translates at the filesystem call and nowhere else.
class HostPathBridge {
  const HostPathBridge({required this.toHost, required this.fromHost});

  /// The same place as `dart:io` must be given it.
  final String Function(String path) toHost;

  /// The same place as this space spells it.
  final String Function(String hostPath) fromHost;

  /// The spelling is the same on both sides — this machine's own disk.
  static const HostPathBridge same = HostPathBridge(
    toHost: _itself,
    fromHost: _itself,
  );

  static String _itself(String path) => path;
}

/// A filesystem this process can reach with `dart:io`: this machine's own
/// disk, or a WSL distribution over its share. Every failure the filesystem
/// raises becomes a [FileSpaceException] with a sentence a person can read —
/// an `OS Error … errno = 5` in a dialog says nothing to whoever clicked
/// Delete.
class LocalFileSpace extends FileSpace {
  LocalFileSpace({
    required this.environmentId,
    this.label = 'This machine',
    p.Context? pathContext,
    this.bridge = HostPathBridge.same,
    this.homeAt,
  }) : pathContext = pathContext ?? p.context;

  @override
  final String environmentId;

  @override
  final String label;

  @override
  final p.Context pathContext;

  /// How this space's paths reach `dart:io`.
  final HostPathBridge bridge;

  /// Where this space opens, when it is not the user's own home folder — a
  /// distribution's `/home`, say.
  final Future<EnvironmentPath> Function()? homeAt;

  @override
  Future<EnvironmentPath> home() async {
    final given = homeAt;
    if (given != null) return given();
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return EnvironmentPath(environmentId: environmentId, path: home);
  }

  @override
  Future<EnvironmentPath> resolve(EnvironmentPath path) async {
    requireOwnPath(path);
    return _at(pathContext.normalize(path.path));
  }

  @override
  Future<List<FileEntry>> list(EnvironmentPath directory) async {
    requireOwnPath(directory);
    final entries = <FileEntry>[];
    try {
      await for (final entity in Directory(
        bridge.toHost(directory.path),
      ).list(followLinks: false)) {
        final stat = await entity.stat();
        final path = bridge.fromHost(entity.path);
        entries.add(
          FileEntry(
            name: pathContext.basename(path),
            path: _at(path),
            kind: switch (entity) {
              Directory() => FileEntryKind.directory,
              Link() => FileEntryKind.symlink,
              File() => FileEntryKind.file,
              _ => FileEntryKind.other,
            },
            sizeBytes: stat.type == FileSystemEntityType.file
                ? stat.size
                : null,
            modifiedAt: stat.modified,
          ),
        );
      }
    } on FileSystemException catch (error) {
      throw FileSpaceException(
        'Cannot open ${directory.path}: ${_why(error)}',
        cause: error,
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<EnvironmentPath> createDirectory(
    EnvironmentPath parent,
    String name,
  ) async {
    final target = _target(parent, name);
    await _guard(
      'Cannot create the folder "$name"',
      () => Directory(bridge.toHost(target.path)).create(),
    );
    return target;
  }

  @override
  Future<EnvironmentPath> createFile(
    EnvironmentPath parent,
    String name,
  ) async {
    final target = _target(parent, name);
    await _guard('Cannot create "$name"', () async {
      final file = File(bridge.toHost(target.path));
      // Never `create` alone: it is a no-op on a file that exists, and the
      // browser would report having made one that was already there.
      if (await file.exists()) {
        throw const FileSpaceException('something with that name is here');
      }
      await file.create();
    });
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
    await _guard('Cannot rename to "$name"', () async {
      final entity = await _entityAt(target.path);
      await entity.rename(bridge.toHost(renamed.path));
    });
    return renamed;
  }

  @override
  Future<void> delete(EnvironmentPath target, {bool recursive = false}) async {
    requireOwnPath(target);
    await _guard(
      'Cannot delete ${pathContext.basename(target.path)}',
      () async {
        final entity = await _entityAt(target.path);
        await entity.delete(recursive: recursive);
      },
    );
  }

  @override
  Future<void> copyToLocal(
    EnvironmentPath source,
    String destination, {
    void Function(int bytes)? onProgress,
  }) {
    requireOwnPath(source);
    return _copy(bridge.toHost(source.path), destination, onProgress);
  }

  @override
  Future<void> copyFromLocal(
    String source,
    EnvironmentPath destination, {
    void Function(int bytes)? onProgress,
  }) {
    requireOwnPath(destination);
    return _copy(source, bridge.toHost(destination.path), onProgress);
  }

  @override
  Future<void> close() async {}

  /// A copy where both ends are reachable with `dart:io` is still a copy: the
  /// same bytes and the same progress, so nothing above needs a second path
  /// for "this side is not remote".
  Future<void> _copy(
    String from,
    String to,
    void Function(int bytes)? onProgress,
  ) => _guard('Cannot copy ${p.basename(from)}', () async {
    final sink = File(to).openWrite();
    var moved = 0;
    try {
      await for (final chunk in File(from).openRead()) {
        sink.add(chunk);
        moved += chunk.length;
        onProgress?.call(moved);
      }
    } finally {
      await sink.close();
    }
  });

  EnvironmentPath _at(String path) =>
      EnvironmentPath(environmentId: environmentId, path: path);

  EnvironmentPath _target(EnvironmentPath parent, String name) {
    requireOwnPath(parent);
    final refusal = nameRefusal(name);
    if (refusal != null) throw FileSpaceException(refusal);
    return child(parent, name.trim());
  }

  /// The entity at [path] as it is on disk — a directory deleted as a file
  /// fails on some platforms and does nothing at all on others.
  Future<FileSystemEntity> _entityAt(String path) async {
    final host = bridge.toHost(path);
    final type = await FileSystemEntity.type(host, followLinks: false);
    return switch (type) {
      FileSystemEntityType.directory => Directory(host),
      FileSystemEntityType.link => Link(host),
      FileSystemEntityType.notFound => throw const FileSpaceException(
        'it is not there any more',
      ),
      _ => File(host),
    };
  }

  Future<void> _guard(String what, Future<void> Function() body) async {
    try {
      await body();
    } on FileSpaceException catch (error) {
      throw FileSpaceException('$what: ${error.message}', cause: error.cause);
    } on FileSystemException catch (error) {
      throw FileSpaceException('$what: ${_why(error)}', cause: error);
    }
  }

  /// The part of a [FileSystemException] worth showing: the OS's own reason,
  /// or the message when it gave none.
  static String _why(FileSystemException error) {
    final os = error.osError?.message;
    return (os == null || os.isEmpty) ? error.message : os.toLowerCase();
  }
}

/// A WSL distribution's files, read and written over `\\wsl.localhost` —
/// measured at under a millisecond warm, against interop's ~72 ms per spawn
/// (PROJECT.md §18). Paths stay POSIX everywhere but the filesystem call.
LocalFileSpace wslFileSpace({
  required String environmentId,
  required String distribution,
  required String label,
}) => LocalFileSpace(
  environmentId: environmentId,
  label: label,
  pathContext: p.posix,
  bridge: HostPathBridge(
    toHost: (path) => wslSharePath(distribution, path),
    fromHost: (hostPath) => wslPosixPath(distribution, hostPath),
  ),
  // `/home` rather than a guess at the user's own folder: one tap in beats a
  // path that is wrong on a distribution with another login.
  homeAt: () async =>
      EnvironmentPath(environmentId: environmentId, path: '/home'),
);

/// The `\\wsl.localhost` spelling of a POSIX path in [distribution].
String wslSharePath(String distribution, String posixPath) {
  final trimmed = posixPath.replaceAll(RegExp(r'^/+'), '');
  final tail = trimmed.replaceAll('/', r'\');
  final root = r'\\wsl.localhost\' + distribution;
  return tail.isEmpty ? root : '$root\\$tail';
}

/// The POSIX path a `\\wsl.localhost` path names, back again.
String wslPosixPath(String distribution, String hostPath) {
  final root = r'\\wsl.localhost\' + distribution;
  if (!hostPath.toLowerCase().startsWith(root.toLowerCase())) return hostPath;
  final tail = hostPath.substring(root.length).replaceAll(r'\', '/');
  return tail.isEmpty ? '/' : (tail.startsWith('/') ? tail : '/$tail');
}
