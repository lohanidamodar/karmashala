import 'dart:async';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/values.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// A file operation that did not happen, in the words a person is shown.
class FilesException implements Exception {
  const FilesException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The server did not answer — a dropped SSH link, a server away — so
/// nothing was learned about the file. A buffer keeps its text over it.
class FilesUnreachableException extends FilesException {
  const FilesUnreachableException(super.message);
}

/// A save refused because the file on disk is not the version it expected.
class FilesStaleException extends FilesException {
  FilesStaleException(this.current)
    : super(
        current == null
            ? 'The file is no longer on disk.'
            : 'The file changed on disk.',
      );

  /// What is there now; null when the file is gone.
  final FileStamp? current;
}

/// **A machine's files, asked of the server** (slice 3c): the file pane, the
/// editor's reads and saves, the "Browse…" dialogs and Quick Open go through
/// here, and nothing here touches a disk. A path is spelled the way its own
/// environment spells it, both ways; the one spelling for this machine the
/// server ever hands over is [localPathOf]'s, and only when it runs here.
class FilesClient {
  FilesClient(this._client) {
    _changes = _client.fileChanges.listen(_changed);
    _connection = _client.connectionChanges.listen((connection) {
      // A new link watches nothing: ask again for everything still wanted.
      if (connection.state == DataLinkState.connected && _watches.isNotEmpty) {
        unawaited(_send(FilesWatch([..._watches.keys])));
      }
    });
  }

  final DataClient _client;
  late final StreamSubscription<FileChanged> _changes;
  late final StreamSubscription<DataConnection> _connection;

  /// Who is watching each path, by the handle each was given.
  final _watches = <EnvironmentPath, Set<FileWatch>>{};

  /// Whether the server runs on this machine: then a file it reaches with
  /// `dart:io` opens here too, by the path [localPathOf] answers.
  bool get serverOnThisMachine => _client.serverOnThisMachine;

  Future<void> dispose() async {
    await _changes.cancel();
    await _connection.cancel();
    _watches.clear();
  }

  Future<R> _send<R>(FilesWorkRequest<R> request) async {
    try {
      return (await _client.send(request)).value;
    } on DataRefused catch (refusal) {
      throw switch (refusal.code) {
        DataRefusalCode.unavailable => FilesUnreachableException(
          refusal.message,
        ),
        DataRefusalCode.conflict => FilesStaleException(null),
        _ => FilesException(refusal.message),
      };
    }
  }

  /// Where a browser opens in [environmentId].
  Future<EnvironmentPath> home(String environmentId) =>
      _send(FilesHome(environmentId));

  /// [path] made absolute, with the server's own spelling of it.
  Future<ResolvedPath> resolve(EnvironmentPath path) =>
      _send(FilesResolve(path));

  /// The entries of the folder [path], directories first.
  Future<List<FileEntry>> list(EnvironmentPath path) => _send(FilesList(path));

  /// What is at [path]; absent is an answer.
  Future<FileStat> stat(EnvironmentPath path) => _send(FilesStatOf(path));

  /// [length] bytes of [path] from [offset], or to its end — asked a chunk at
  /// a time, so no answer comes near a frame's size.
  Future<Uint8List> read(
    EnvironmentPath path, {
    int offset = 0,
    int? length,
  }) async {
    final bytes = BytesBuilder(copy: false);
    var at = offset;
    while (true) {
      final left = length == null ? kFileChunkBytes : length - bytes.length;
      if (left <= 0) break;
      final chunk = await _send(
        FilesRead(
          path,
          offset: at,
          length: left < kFileChunkBytes ? left : kFileChunkBytes,
        ),
      );
      bytes.add(chunk.bytes);
      at += chunk.bytes.length;
      if (chunk.bytes.isEmpty || at >= chunk.fileSize) break;
    }
    return bytes.takeBytes();
  }

  /// Replaces [path] with [bytes] if [expect] accepts what is on disk, and
  /// answers the stamp now there. Throws [FilesStaleException] with what is
  /// there when refused.
  Future<FileStamp> write(
    EnvironmentPath path,
    Uint8List bytes, {
    required WriteExpectation expect,
  }) async {
    try {
      return await _send(FilesWrite(path, bytes, expect: expect));
    } on FilesStaleException {
      FileStamp? current;
      try {
        current = (await stat(path)).stamp;
      } on FilesException {
        // What is there is unknown; the refusal still stands.
      }
      throw FilesStaleException(current);
    }
  }

  Future<EnvironmentPath> createDirectory(
    EnvironmentPath parent,
    String name,
  ) => _send(FilesMkdir(parent, name));

  Future<EnvironmentPath> createFile(EnvironmentPath parent, String name) =>
      _send(FilesTouch(parent, name));

  Future<EnvironmentPath> rename(EnvironmentPath path, String name) =>
      _send(FilesRename(path, name));

  Future<void> delete(EnvironmentPath path, {bool recursive = false}) =>
      _send(FilesDelete(path, recursive: recursive));

  /// Copies the file [source] into the folder [toDirectory] — on any machine
  /// the server reaches — and answers where it landed.
  Future<EnvironmentPath> copy(
    EnvironmentPath source,
    EnvironmentPath toDirectory, {
    String? name,
  }) => _send(FilesCopy(source, toDirectory, fileName: name));

  /// Puts [size] bytes of this machine's, named [name], on the server's disk
  /// (slice 5e: a drop on a client whose server is elsewhere) — in
  /// [directory] or, null, the server's uploads folder — in 1 MiB pieces.
  /// Answers where it landed. The caller reads the file; this only sends.
  Future<EnvironmentPath> upload(
    String name,
    int size,
    Stream<List<int>> content, {
    String environmentId = localHostEnvironmentId,
    EnvironmentPath? directory,
  }) async {
    final id = await _send(
      FilesUploadBegin(
        environmentId,
        directory: directory,
        fileName: name,
        size: size,
      ),
    );
    var sent = 0;
    final pending = BytesBuilder(copy: false);
    Future<void> flush() async {
      final bytes = pending.takeBytes();
      await _send(FilesUploadChunk(environmentId, id, offset: sent, bytes: bytes));
      sent += bytes.length;
    }

    await for (final piece in content) {
      pending.add(piece);
      while (pending.length >= kFileChunkBytes) {
        final all = pending.takeBytes();
        pending.add(Uint8List.sublistView(all, kFileChunkBytes));
        await _send(
          FilesUploadChunk(
            environmentId,
            id,
            offset: sent,
            bytes: Uint8List.sublistView(all, 0, kFileChunkBytes),
          ),
        );
        sent += kFileChunkBytes;
      }
    }
    if (pending.isNotEmpty) await flush();
    return _send(FilesUploadCommit(environmentId, id));
  }

  /// Every file under the checkout [root], from the server's index.
  Future<RepoFiles> index(EnvironmentPath root) => _send(FilesIndex(root));

  /// Whether a file at [path] could be opened on this machine at all — the
  /// server is here and the file is not on an SSH host. Cheap: a menu asks
  /// it while it builds.
  bool canOpenHere(EnvironmentPath path) {
    if (!serverOnThisMachine) return false;
    final environment = _client.environments.view[path.environmentId];
    return environment == null
        ? path.environmentId == localHostEnvironmentId
        : environment.kind != EnvironmentKind.ssh;
  }

  /// [path] as this machine's own programs open it — a file manager, an
  /// external editor — or null where there is none: the server elsewhere, or
  /// a file on an SSH host. The server spells it; nothing here translates.
  Future<String?> localPathOf(EnvironmentPath path) async {
    if (!canOpenHere(path)) return null;
    return (await resolve(path)).localPath;
  }

  /// Tells [onChange] each time [path] changes on disk until the handle is
  /// cancelled. One watch per path is asked of the server however many
  /// handles hold it.
  FileWatch watch(EnvironmentPath path, void Function(FileChanged) onChange) {
    final handle = FileWatch._(this, path, onChange);
    final holders = _watches.putIfAbsent(path, () => {});
    final first = holders.isEmpty;
    holders.add(handle);
    if (first) unawaited(_quietly(_send(FilesWatch([path]))));
    return handle;
  }

  void _unwatch(FileWatch handle) {
    final holders = _watches[handle.path];
    if (holders == null || !holders.remove(handle)) return;
    if (holders.isNotEmpty) return;
    _watches.remove(handle.path);
    unawaited(_quietly(_send(FilesUnwatch([handle.path]))));
  }

  /// A watch that could not be placed is a missed notice, not an error: the
  /// next reconnect asks again, and a reader can still refresh.
  static Future<void> _quietly(Future<Object?> asked) =>
      asked.then<void>((_) {}, onError: (Object _) {});

  void _changed(FileChanged change) {
    for (final handle in [...?_watches[change.at]]) {
      handle._onChange(change);
    }
  }
}

/// One holder's watch of a path; [cancel] to stop hearing of it.
class FileWatch {
  FileWatch._(this._files, this.path, this._onChange);

  final FilesClient _files;
  final EnvironmentPath path;
  final void Function(FileChanged) _onChange;

  void cancel() => _files._unwatch(this);
}

/// The folder [path] is in, or null at its root — worked out in the spelling
/// the path is already written in: a drive or a backslash is Windows', the
/// rest POSIX. Nothing is translated.
EnvironmentPath? parentOf(EnvironmentPath path) {
  final context = pathContextOf(path.path);
  final parent = context.dirname(path.path);
  if (parent == path.path || parent.isEmpty || parent == '.') return null;
  return EnvironmentPath(environmentId: path.environmentId, path: parent);
}

/// How [path] separates itself.
p.Context pathContextOf(String path) =>
    RegExp(r'^[A-Za-z]:|\\').hasMatch(path) ? p.windows : p.posix;

final filesClientProvider = Provider<FilesClient>((ref) {
  final files = FilesClient(ref.watch(dataClientProvider));
  ref.onDispose(files.dispose);
  return files;
});
