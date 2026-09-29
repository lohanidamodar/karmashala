part of 'fake_data_server.dart';

/// The files a [FakeDataServer] reads and writes (slice 3c) — the file pane,
/// the editor's buffers, the "Browse…" dialogs, Quick Open — answered by the
/// same file spaces the server runs (`karmashala_files`): this machine's disk
/// (a test's temp folder) for `windows` and anything else a test puts in
/// [spaces]. A watch is kept per link, as the server keeps it: [changed]
/// tells the links watching a path, and a write here tells them at once.
class FakeFilesWork {
  FakeFilesWork._();

  /// Every file request, in the order asked.
  final asked = <FilesWorkRequest<Object?>>[];

  /// The kinds asked, in order.
  List<String> get kinds => [for (final r in asked) r.kind];

  /// The space each environment is read through. `windows` is this machine.
  final spaces = <String, FileSpace>{
    localHostEnvironmentId: LocalFileSpace(
      environmentId: localHostEnvironmentId,
    ),
  };

  /// Environments that do not answer: every request there is refused
  /// `unavailable`, as a dropped SSH link is.
  final offline = <String>{};

  /// Answers a request before the defaults do; return [unhandled] to fall
  /// through. May be async, and may throw a [DataRefused].
  FutureOr<Object?> Function(FilesWorkRequest<Object?> request)? answer;

  /// What [answer] returns to leave a request to the defaults.
  static const Object unhandled = _Unhandled();

  /// A refusal the next request of that kind gets, once.
  final refusals = <String, DataRefused>{};

  /// Quick Open's answers, by checkout; one not here is walked.
  final indexes = <EnvironmentPath, RepoFiles>{};

  /// Puts a machine at [environmentId] whose POSIX paths (`/home/me/app`) are
  /// kept under [root] on this disk — how a test stands up "an SSH host" or
  /// "a WSL distribution" the server reads: the app sees only POSIX paths in
  /// that environment, as it would of the real one.
  void posixAt(String environmentId, String root) {
    String toHost(String path) {
      final tail = path.replaceAll(RegExp(r'^/+'), '');
      return tail.isEmpty ? root : p.joinAll([root, ...tail.split('/')]);
    }

    String fromHost(String hostPath) {
      final relative = p.relative(hostPath, from: root);
      if (relative == '.') return '/';
      return '/${p.split(relative).join('/')}';
    }

    spaces[environmentId] = LocalFileSpace(
      environmentId: environmentId,
      label: environmentId,
      pathContext: p.posix,
      bridge: HostPathBridge(toHost: toHost, fromHost: fromHost),
      atomicReplace: false,
      homeAt: () async =>
          EnvironmentPath(environmentId: environmentId, path: '/home/me'),
    );
  }

  /// Which links watch which path.
  final _watchers = <EnvironmentPath, Set<FakeDataLink>>{};

  /// Every path some link watches now.
  Set<EnvironmentPath> get watched => {..._watchers.keys};

  /// [path] changed on disk: every link watching it is told, with [stamp]
  /// — or with what the space stats now, when not given.
  Future<void> changed(EnvironmentPath path, {FileStamp? stamp}) async {
    final links = _watchers[path];
    if (links == null || links.isEmpty) return;
    var now = stamp;
    if (now == null) {
      try {
        now = (await spaces[path.environmentId]?.stat(path))?.stamp;
      } on Object {
        now = null;
      }
    }
    final change = FileChanged(
      environmentId: path.environmentId,
      path: path.path,
      stamp: now,
    );
    for (final link in [...links]) {
      link.tell([change]);
    }
  }

  void _closed(FakeDataLink link) {
    for (final links in _watchers.values) {
      links.remove(link);
    }
    _watchers.removeWhere((_, links) => links.isEmpty);
  }

  FileSpace _space(String environmentId) {
    if (offline.contains(environmentId)) {
      throw DataRefused.unavailable(
        'Cannot reach $environmentId: the connection was lost',
      );
    }
    return spaces[environmentId] ??
        (throw DataRefused.notFound(
          'this server cannot reach files in "$environmentId"',
        ));
  }

  Future<Object?> _handle(
    FilesWorkRequest<Object?> request,
    FakeDataLink link,
  ) async {
    asked.add(request);
    final refused = refusals.remove(request.kind);
    if (refused != null) throw refused;
    final scripted = await answer?.call(request);
    if (scripted != null && scripted is! _Unhandled) return scripted;
    try {
      return await _default(request, link);
    } on FileStaleException catch (error) {
      throw DataRefused(DataRefusalCode.conflict, error.message);
    } on FileUnreachableException catch (error) {
      throw DataRefused.unavailable(error.message);
    } on FileSpaceException catch (error) {
      throw DataRefused(DataRefusalCode.failed, error.message);
    }
  }

  Future<Object?> _default(
    FilesWorkRequest<Object?> request,
    FakeDataLink link,
  ) async {
    switch (request) {
      case FilesHome(:final environmentId):
        return _space(environmentId).home();
      case FilesResolve(:final path):
        final space = _space(path.environmentId);
        final resolved = await space.resolve(path);
        return ResolvedPath(resolved, localPath: space.hostPathOf(resolved));
      case FilesList(:final path):
        return _space(path.environmentId).list(path);
      case FilesStatOf(:final path):
        return _space(path.environmentId).stat(path);
      case FilesRead(:final path, :final offset, :final length):
        final space = _space(path.environmentId);
        final stat = await space.stat(path);
        if (!stat.exists) throw DataRefused.notFound('${path.path} is gone');
        final left = stat.size - offset;
        final bytes = left <= 0
            ? Uint8List(0)
            : await space.read(
                path,
                offset: offset,
                length: length < left ? length : left,
              );
        return FileChunk(bytes, fileSize: stat.size);
      case FilesWrite(:final path, :final bytes, :final expect):
        final stamp = await _space(
          path.environmentId,
        ).write(path, bytes, expect: expect);
        await _moved(path);
        return stamp;
      case FilesMkdir(:final parent, :final folderName):
        final made = await _space(
          parent.environmentId,
        ).createDirectory(parent, folderName);
        await _moved(made);
        return made;
      case FilesTouch(:final parent, :final fileName):
        final made = await _space(
          parent.environmentId,
        ).createFile(parent, fileName);
        await _moved(made);
        return made;
      case FilesRename(:final path, :final newName):
        final renamed = await _space(
          path.environmentId,
        ).rename(path, newName);
        await _moved(path);
        await _moved(renamed);
        return renamed;
      case FilesDelete(:final path, :final recursive):
        await _space(path.environmentId).delete(path, recursive: recursive);
        await _moved(path);
        return const DataAck();
      case FilesTrash(:final path):
        // No recycle bin in a fake: gone is what the client can observe.
        await _space(path.environmentId).delete(path, recursive: true);
        await _moved(path);
        return const DataAck();
      case FilesCopy(:final source, :final toDirectory, :final fileName):
        final landed = await const FileTransfer().copy(
          from: _space(source.environmentId),
          source: source,
          to: _space(toDirectory.environmentId),
          destination: toDirectory,
          name: fileName,
        );
        await _moved(landed);
        return landed;
      case FilesIndex(:final root):
        final scripted = indexes[root];
        if (scripted != null) return scripted;
        final walk = RepoFileIndex(
          spaces: (id) => spaces[id],
          watcher: DirectoryChangeWatcher(recursiveWatchSupported: false),
        );
        try {
          return await walk.index(root);
        } finally {
          walk.dispose();
        }
      case FilesWatch(:final paths):
        for (final path in paths) {
          _watchers.putIfAbsent(path, () => {}).add(link);
        }
        return const DataAck();
      case FilesUnwatch(:final paths):
        for (final path in paths) {
          final links = _watchers[path];
          links?.remove(link);
          if (links != null && links.isEmpty) _watchers.remove(path);
        }
        return const DataAck();
      case FilesUploadBegin(
        :final environmentId,
        :final directory,
        :final fileName,
      ):
        final id = 'upload-${_uploads.length + 1}';
        _uploads[id] = (
          directory ?? await _space(environmentId).home(),
          fileName,
          BytesBuilder(),
        );
        return id;
      case FilesUploadChunk(:final uploadId, :final bytes):
        _uploads[uploadId]!.$3.add(bytes);
        return const DataAck();
      case FilesUploadCommit(:final environmentId, :final uploadId):
        final (directory, name, bytes) = _uploads.remove(uploadId)!;
        final space = _space(environmentId);
        final target = space.child(directory, name);
        await space.write(
          target,
          bytes.takeBytes(),
          expect: const WriteExpectation.any(),
        );
        uploaded.add(target);
        return target;
      case FilesUploadAbort(:final uploadId):
        _uploads.remove(uploadId);
        return const DataAck();
    }
  }

  final _uploads = <String, (EnvironmentPath, String, BytesBuilder)>{};

  /// Where each finished upload landed (slice 5e).
  final uploaded = <EnvironmentPath>[];

  /// What the server tells after its own write: the path and its folder.
  Future<void> _moved(EnvironmentPath path) async {
    await changed(path);
    final parent = spaces[path.environmentId]?.parentOf(path);
    if (parent != null) await changed(parent);
  }
}
