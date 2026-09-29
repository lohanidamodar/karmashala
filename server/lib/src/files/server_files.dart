import 'dart:async';
import 'dart:io' hide FileStat;
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/karmashala_files.dart';

import '../data/data_service.dart';
import '../data/files_work.dart';
import 'file_watches.dart';
import 'recycle_bin.dart';

/// **A machine's files, for every client** (slice 3c): the file pane, the
/// editor's reads and saves, the "Browse…" dialogs, the Files tab's copies
/// and Quick Open's index all run here, where the files are — this machine,
/// its WSL distributions over their share, an SSH host over the server's own
/// SFTP (3a's pool, so a key never leaves the server). With the app closed or
/// on another machine they answer the same.
///
/// A client names a path the way its own environment spells it and gets it
/// back the same way; the one spelling it is ever handed for the server's
/// own disk is `files.resolve`'s `localPath`, for a client on this machine to
/// give its file manager or editor.
class ServerFiles implements FilesWork {
  ServerFiles({
    required this.data,
    this.remoteSpace,
    this.defaultDirectoryOf,
    this.uploadsDirectory,
    bool? windowsHost,
    FileWatches? watches,
    RepoFileIndex? index,
    Duration localInterval = const Duration(seconds: 2),
    Duration remoteInterval = const Duration(seconds: 5),
  }) : _windowsHost = windowsHost ?? Platform.isWindows {
    this.watches =
        watches ??
        FileWatches(
          stat: (path) async => (await _stat(path)).stamp,
          // Looked over at least as often as the shortest cadence wants.
          tick: localInterval < const Duration(milliseconds: 500)
              ? localInterval
              : const Duration(milliseconds: 500),
          intervalOf: (id) => _isSsh(id) ? remoteInterval : localInterval,
        );
    this.index = index ?? RepoFileIndex(spaces: spaceFor);
    data.addChangeListener(_changed);
  }

  final DataService data;

  /// An SSH environment's files, from the server's ssh domain (its own
  /// SFTP, 3a); null reaches no SSH host.
  final FileSpace? Function(ExecutionEnvironment environment)? remoteSpace;

  /// The folder a saved SSH host names to start in.
  final String? Function(String hostId)? defaultDirectoryOf;

  /// Where an upload that names no folder lands on this machine (slice 5e):
  /// `<data dir>/uploads`. Null refuses such an upload.
  final String? uploadsDirectory;

  /// Whether WSL's share is there to read a distribution through.
  final bool _windowsHost;

  final _uploads = <String, _Upload>{};
  var _lastUpload = 0;

  late final FileWatches watches;
  late final RepoFileIndex index;

  final _spaces = <String, FileSpace>{};

  /// Answers the clients' file work from now on.
  void attach() => data.filesWork = this;

  Future<void> close() async {
    data.removeChangeListener(_changed);
    if (identical(data.filesWork, this)) data.filesWork = null;
    await watches.close();
    index.dispose();
    for (final space in _spaces.values.toList()) {
      await space.close();
    }
    _spaces.clear();
  }

  @override
  void linkClosed(FileWatchLink link) {
    watches.closed(link);
    for (final entry in _uploads.entries.toList()) {
      if (!identical(entry.value.link, link)) continue;
      _uploads.remove(entry.key);
      unawaited(entry.value.discard());
    }
  }

  @override
  Future<Object?> handle(
    FilesWorkRequest<Object?> request,
    FileWatchLink link,
  ) async {
    try {
      return await _handle(request, link);
    } on DataRefused {
      rethrow;
    } on FileStaleException catch (error) {
      throw DataRefused(DataRefusalCode.conflict, error.message);
    } on FileUnreachableException catch (error) {
      throw DataRefused.unavailable(error.message);
    } on FileSpaceException catch (error) {
      throw DataRefused(DataRefusalCode.failed, error.message);
    }
  }

  Future<Object?> _handle(
    FilesWorkRequest<Object?> request,
    FileWatchLink link,
  ) async {
    switch (request) {
      case FilesHome(:final environmentId):
        return _home(environmentId);
      case FilesResolve(:final path):
        final space = _space(path);
        final resolved = await space.resolve(path);
        return ResolvedPath(resolved, localPath: space.hostPathOf(resolved));
      case FilesList(:final path):
        return _space(path).list(path);
      case FilesStatOf(:final path):
        return _stat(path);
      case FilesRead(:final path, :final offset, :final length):
        if (offset < 0 || length < 0) {
          throw const DataRefused.invalid('files.read: a negative range');
        }
        final space = _space(path);
        final stat = await space.stat(path);
        if (!stat.exists) {
          throw DataRefused.notFound('${path.path} is not there');
        }
        if (stat.isDirectory) {
          throw DataRefused.invalid('${path.path} is a folder, not a file');
        }
        final want = length > kFileChunkBytes ? kFileChunkBytes : length;
        final left = stat.size - offset;
        final bytes = left <= 0 || want == 0
            ? Uint8List(0)
            : await space.read(
                path,
                offset: offset,
                length: want < left ? want : left,
              );
        return FileChunk(bytes, fileSize: stat.size);
      case FilesWrite(:final path, :final bytes, :final expect):
        if (bytes.length > kFileWriteBytes) {
          throw DataRefused.invalid(
            'files.write: over ${kFileWriteBytes ~/ (1024 * 1024)} MiB',
          );
        }
        final stamp = await _space(path).write(path, bytes, expect: expect);
        await _moved(path);
        return stamp;
      case FilesMkdir(:final parent, :final folderName):
        _name(folderName);
        final made = await _space(parent).createDirectory(parent, folderName);
        await _moved(made);
        return made;
      case FilesTouch(:final parent, :final fileName):
        _name(fileName);
        final made = await _space(parent).createFile(parent, fileName);
        await _moved(made);
        return made;
      case FilesRename(:final path, :final newName):
        _name(newName);
        final renamed = await _space(path).rename(path, newName);
        await _moved(path, also: renamed);
        return renamed;
      case FilesDelete(:final path, :final recursive):
        final space = _space(path);
        _refuseProtected(space, path);
        await space.delete(path, recursive: recursive);
        await _gone(path);
        return const DataAck();
      case FilesTrash(:final path):
        final space = _space(path);
        _refuseProtected(space, path);
        final host = space is LocalFileSpace ? space.hostPathOf(path) : null;
        if (host == null || !canRecycle(host)) {
          throw DataRefused.invalid(
            '${path.path} is on ${space.label}, which has no recycle bin '
            'this server can reach.',
          );
        }
        if (!(await space.stat(path)).exists) {
          throw DataRefused.notFound('${path.path} is not there any more.');
        }
        try {
          await moveToRecycleBin(host);
        } on RecycleBinException catch (error) {
          throw DataRefused(
            DataRefusalCode.failed,
            'Cannot move ${space.pathContext.basename(path.path)} to the '
            'recycle bin: ${error.message}',
          );
        }
        await _gone(path);
        return const DataAck();
      case FilesCopy(:final source, :final toDirectory, :final fileName):
        if (fileName != null) _name(fileName);
        final from = _space(source);
        final to = _space(toDirectory);
        final stat = await from.stat(source);
        if (stat.isDirectory) {
          throw const DataRefused.invalid(
            'Only files can be copied between machines, not folders.',
          );
        }
        final landed = await const FileTransfer().copy(
          from: from,
          source: source,
          to: to,
          destination: toDirectory,
          name: fileName,
          totalBytes: stat.exists ? stat.size : null,
        );
        await _moved(landed);
        return landed;
      case FilesIndex(:final root):
        _space(root);
        return index.index(root);
      case FilesWatch(:final paths):
        for (final path in paths) {
          _space(path);
        }
        await watches.watch(link, paths);
        return const DataAck();
      case FilesUnwatch(:final paths):
        watches.unwatch(link, paths);
        return const DataAck();
      case FilesUploadBegin():
        return _beginUpload(request, link);
      case FilesUploadChunk(:final uploadId, :final offset, :final bytes):
        final upload = _upload(uploadId, link);
        if (offset != upload.received) {
          throw DataRefused.invalid(
            'files.upload.chunk: expected offset ${upload.received}, got '
            '$offset',
          );
        }
        if (bytes.length > kFileChunkBytes ||
            upload.received + bytes.length > upload.size) {
          throw const DataRefused.invalid(
            'files.upload.chunk: more than the upload announced',
          );
        }
        await upload.sink.add(bytes);
        upload.received += bytes.length;
        return const DataAck();
      case FilesUploadCommit(:final uploadId):
        final upload = _upload(uploadId, link);
        _uploads.remove(uploadId);
        try {
          if (upload.received != upload.size) {
            throw DataRefused.invalid(
              'files.upload.commit: ${upload.received} of ${upload.size} '
              'bytes arrived',
            );
          }
          await upload.sink.close();
          final landed = await _placeUpload(upload);
          await _moved(landed);
          return landed;
        } finally {
          await upload.discard();
        }
      case FilesUploadAbort(:final uploadId):
        final upload = _uploads[uploadId];
        if (upload != null && identical(upload.link, link)) {
          _uploads.remove(uploadId);
          await upload.discard();
        }
        return const DataAck();
    }
  }

  Future<String> _beginUpload(FilesUploadBegin request, FileWatchLink link) async {
    _name(request.fileName);
    if (request.size < 0 || request.size > kMaxUploadBytes) {
      throw DataRefused.invalid(
        'files.upload.begin: a file of ${request.size} bytes is over the '
        '${kMaxUploadBytes ~/ (1024 * 1024)} MiB an upload carries',
      );
    }
    final directory = request.directory;
    if (directory == null) {
      final here = uploadsDirectory;
      final space = _spaceIn(request.environmentId);
      if (here == null || space is! LocalFileSpace) {
        throw const DataRefused.invalid(
          'files.upload.begin: name a folder; this server keeps an uploads '
          'folder only on its own machine',
        );
      }
    } else {
      _space(directory);
    }
    final staging = await Directory.systemTemp.createTemp('ks-upload-');
    final file = File('${staging.path}${Platform.pathSeparator}part');
    final id = 'upload-${++_lastUpload}';
    _uploads[id] = _Upload(
      link: link,
      environmentId: request.environmentId,
      directory: directory,
      fileName: request.fileName,
      size: request.size,
      staging: staging,
      file: file,
      sink: _Sink(file.openWrite()),
    );
    return id;
  }

  _Upload _upload(String id, FileWatchLink link) {
    final upload = _uploads[id];
    if (upload == null || !identical(upload.link, link)) {
      throw DataRefused.notFound('no upload $id on this link');
    }
    return upload;
  }

  /// Puts a finished upload in place under a name nothing there has.
  Future<EnvironmentPath> _placeUpload(_Upload upload) async {
    final space = _spaceIn(upload.environmentId);
    var directory = upload.directory;
    if (directory == null) {
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final folder = Directory(
        '$uploadsDirectory${Platform.pathSeparator}$day',
      );
      await folder.create(recursive: true);
      directory = EnvironmentPath(
        environmentId: upload.environmentId,
        path: folder.path,
      );
    }
    final dot = upload.fileName.lastIndexOf('.');
    final stem = dot > 0 ? upload.fileName.substring(0, dot) : upload.fileName;
    final extension = dot > 0 ? upload.fileName.substring(dot) : '';
    var target = space.child(directory, upload.fileName);
    for (var n = 2; (await space.stat(target)).exists; n++) {
      target = space.child(directory, '$stem ($n)$extension');
    }
    final here = space.hostPathOf(target);
    if (here != null) {
      await upload.file.copy(here);
    } else {
      await space.copyFromLocal(upload.file.path, target);
    }
    return target;
  }

  static void _name(String name) {
    final refusal = nameRefusal(name);
    if (refusal != null) throw DataRefused.invalid(refusal);
  }

  Future<FileStat> _stat(EnvironmentPath path) => _space(path).stat(path);

  /// The server itself moved [path] (and [also]): whoever watches it, or
  /// the folder it is in, hears now rather than at the next look, and Quick
  /// Open walks the checkouts it is under again.
  Future<void> _moved(EnvironmentPath path, {EnvironmentPath? also}) async {
    final space = _space(path);
    final touched = [path, ?also, ?space.parentOf(path)];
    for (final one in touched) {
      index.touchUnder(one);
    }
    await watches.check(touched);
  }

  /// [path] went, with whatever was under it: an editor on a file inside a
  /// deleted folder hears too, not only the folder's own watchers.
  Future<void> _gone(EnvironmentPath path) async {
    await _moved(path);
    await watches.check([path], under: true);
  }

  /// A delete that would take a disk's root, a project or checkout the
  /// workspace names, or a folder holding one, is refused whoever asks —
  /// those are removed through the workspace, not a file browser.
  void _refuseProtected(FileSpace space, EnvironmentPath path) {
    final context = space.pathContext;
    final here = context.normalize(path.path);
    if (context.dirname(here) == here || context.rootPrefix(here) == here) {
      throw DataRefused.invalid('${path.path} is the root of a disk.');
    }
    for (final root in data.workspaceRoots) {
      if (root.environmentId != path.environmentId) continue;
      if (context.equals(root.path, here)) {
        throw DataRefused.invalid(
          '${path.path} is a project or checkout root; remove it from the '
          'workspace instead.',
        );
      }
      if (context.isWithin(here, root.path)) {
        throw DataRefused.invalid(
          '${path.path} holds the project or checkout at ${root.path}.',
        );
      }
    }
  }

  Future<EnvironmentPath> _home(String environmentId) async {
    final environment = _environment(environmentId);
    final hostId = environment?.sshHostId;
    if (environment?.kind == EnvironmentKind.ssh && hostId != null) {
      final configured = defaultDirectoryOf?.call(hostId);
      if (configured != null && configured.trim().isNotEmpty) {
        return EnvironmentPath(environmentId: environmentId, path: configured);
      }
    }
    return _spaceIn(environmentId).home();
  }

  /// A change told to every client: a checkout an agent worked in, a write
  /// git made, a host edited or gone.
  void _changed(List<DataChange> changes) {
    for (final change in changes) {
      switch (change) {
        case CheckoutTouched(:final directory):
          index.touchUnder(directory);
          unawaited(watches.check([directory], under: true));
        case EnvironmentChanged(:final environment):
          _drop(environment.id);
        case EnvironmentRemoved(:final id):
          _drop(id);
        case SshHostTouched(:final id) || SshHostRemoved(:final id):
          for (final environment in data.environments) {
            if (environment.sshHostId == id) _drop(environment.id);
          }
        default:
          break;
      }
    }
  }

  void _drop(String environmentId) {
    final space = _spaces.remove(environmentId);
    if (space != null) unawaited(space.close());
  }

  FileSpace _space(EnvironmentPath path) => _spaceIn(path.environmentId);

  FileSpace _spaceIn(String environmentId) =>
      spaceFor(environmentId) ??
      (throw DataRefused.notFound(
        'this server cannot reach files in "$environmentId"',
      ));

  /// The space for [environmentId], built once and kept until the
  /// environment or its host changes; null where the server cannot read
  /// files (an unknown environment, WSL off Windows, SSH with no pool).
  FileSpace? spaceFor(String environmentId) {
    final kept = _spaces[environmentId];
    if (kept != null) return kept;
    final built = _build(environmentId);
    if (built != null) _spaces[environmentId] = built;
    return built;
  }

  FileSpace? _build(String environmentId) {
    final environment = _environment(environmentId);
    if (environment == null) {
      return environmentId == localHostEnvironmentId
          ? LocalFileSpace(environmentId: environmentId)
          : null;
    }
    final label = environment.name;
    switch (environment.kind) {
      case EnvironmentKind.windowsNative:
      case EnvironmentKind.localPosix:
        return LocalFileSpace(environmentId: environment.id, label: label);
      case EnvironmentKind.wsl:
        final distribution = environment.wslDistribution;
        if (distribution == null || !_windowsHost) return null;
        return wslFileSpace(
          environmentId: environment.id,
          distribution: distribution,
          label: label,
        );
      case EnvironmentKind.ssh:
        return remoteSpace?.call(environment);
    }
  }

  /// Read from the space already built for a watched path, so a look costs
  /// no store read.
  bool _isSsh(String environmentId) => _spaces[environmentId] is SftpFileSpace;

  ExecutionEnvironment? _environment(String id) =>
      data.environments.where((e) => e.id == id).firstOrNull;
}

/// One file arriving from a client, staged on this machine's disk until it
/// is whole.
class _Upload {
  _Upload({
    required this.link,
    required this.environmentId,
    required this.directory,
    required this.fileName,
    required this.size,
    required this.staging,
    required this.file,
    required this.sink,
  });

  final FileWatchLink link;
  final String environmentId;
  final EnvironmentPath? directory;
  final String fileName;
  final int size;
  final Directory staging;
  final File file;
  final _Sink sink;
  var received = 0;

  Future<void> discard() async {
    await sink.close();
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // A staged file left in the temp folder costs nothing.
    }
  }
}

/// A file being written, closed at most once.
class _Sink {
  _Sink(this._sink);

  final IOSink _sink;
  var _closed = false;

  Future<void> add(Uint8List bytes) async {
    _sink.add(bytes);
    await _sink.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.close();
  }
}
