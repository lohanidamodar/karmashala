part of '../data_request.dart';

// A machine's files, read and written by the server (slice 3c): the file
// pane, the editor's buffers, the "Browse…" dialogs and Quick Open. Each one
// touches a disk or a connection, so each is answered when done
// (`DataSession.handleLater`). A path is always spelled the way its own
// environment spells it — a client never translates one.
//
// Refusals: `notFound` for an environment the server cannot reach files in,
// `unavailable` for one that did not answer (a dropped SSH link), `conflict`
// for a write whose expected stamp is not what is on disk, `invalid` for a
// name or a size a rule refuses, `failed` in the filesystem's own words.

/// The most one `files.read` answers: a bigger file is read in chunks, so no
/// answer comes near the 16 MiB frame (base64 grows a chunk by a third).
const int kFileChunkBytes = 1024 * 1024;

/// The most one `files.write` carries. The editor opens nothing over 512 KiB
/// for editing; this is the frame's bound with base64 room to spare.
const int kFileWriteBytes = 8 * 1024 * 1024;

DataRequest<Object?>? _filesRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      FilesHome.name => FilesHome(args.string('environmentId')),
      FilesResolve.name => FilesResolve(args._path('path')),
      FilesList.name => FilesList(args._path('path')),
      FilesStatOf.name => FilesStatOf(args._path('path')),
      FilesRead.name => FilesRead(
        args._path('path'),
        offset: args.optionalInt('offset') ?? 0,
        length: args.optionalInt('length') ?? kFileChunkBytes,
      ),
      FilesWrite.name => FilesWrite(
        args._path('path'),
        args._bytes('bytes'),
        expect: args.values['expect'] == null
            ? const WriteExpectation.any()
            : args.value('expect', WriteExpectation.fromJson),
      ),
      FilesMkdir.name => FilesMkdir(args._path('parent'), args.string('name')),
      FilesTouch.name => FilesTouch(args._path('parent'), args.string('name')),
      FilesRename.name => FilesRename(args._path('path'), args.string('name')),
      FilesDelete.name => FilesDelete(
        args._path('path'),
        recursive: args.boolean('recursive', orElse: false),
      ),
      FilesCopy.name => FilesCopy(
        args._path('source'),
        args._path('toDirectory'),
        fileName: args.optionalString('name'),
      ),
      FilesIndex.name => FilesIndex(args._path('root')),
      FilesWatch.name => FilesWatch(args._paths('paths')),
      FilesUnwatch.name => FilesUnwatch(args._paths('paths')),
      _ => null,
    };

extension on _Arguments {
  EnvironmentPath _path(String key) => value(key, environmentPathFromJson);

  List<EnvironmentPath> _paths(String key) =>
      objects(key, environmentPathFromJson);

  Uint8List _bytes(String key) {
    final value = values[key];
    if (value is String) {
      try {
        return base64Decode(value);
      } on FormatException {
        // Refused below.
      }
    }
    throw DataRefused.invalid('$kind: "$key" must be base64');
  }
}

/// A machine's files, read and written by the server; answered when done.
sealed class FilesWorkRequest<R> extends DataRequest<R> {
  const FilesWorkRequest();

  /// The environment the request reaches into.
  String get environmentId;
}

/// A request about one path.
sealed class _FilesAt<R> extends FilesWorkRequest<R> {
  const _FilesAt(this.path);

  final EnvironmentPath path;

  @override
  String get environmentId => path.environmentId;

  @override
  Map<String, Object?> argumentsToJson() => {
    'path': environmentPathToJson(path),
  };
}

/// Answered with a path. Not `on DataRequest`: a mixin on the sealed class
/// would be one more subtype every switch over requests must name.
mixin _AnswersPath {
  String get kind;

  Object? resultToJson(EnvironmentPath result) => environmentPathToJson(result);

  EnvironmentPath resultFromJson(Object? json) =>
      _decode(kind, () => environmentPathFromJson(_object(json, kind)));
}

/// Answered with nothing more.
mixin _AnswersAck {
  Object? resultToJson(DataAck result) => null;

  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Where a browser opens in [environmentId]: the home folder (an SSH host's
/// configured default directory first; a WSL distribution's `/home`).
final class FilesHome extends FilesWorkRequest<EnvironmentPath>
    with _AnswersPath {
  const FilesHome(this.environmentId);

  static const String name = 'files.home';

  @override
  final String environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'environmentId': environmentId};
}

/// [path] made absolute, with how the server's own process spells it — what
/// a client on the server's machine hands its file manager or an external
/// editor. The client never works that spelling out itself.
final class FilesResolve extends _FilesAt<ResolvedPath> {
  const FilesResolve(super.path);

  static const String name = 'files.resolve';

  @override
  String get kind => name;

  @override
  Object? resultToJson(ResolvedPath result) => result.toJson();

  @override
  ResolvedPath resultFromJson(Object? json) =>
      _decode(kind, () => ResolvedPath.fromJson(_object(json, kind)));
}

/// The entries of the directory [path]: directories first, then by name.
final class FilesList extends _FilesAt<List<FileEntry>> {
  const FilesList(super.path);

  static const String name = 'files.list';

  @override
  String get kind => name;

  @override
  Object? resultToJson(List<FileEntry> result) => [
    for (final entry in result) entry.toJson(),
  ];

  @override
  List<FileEntry> resultFromJson(Object? json) => _decode(kind, () {
    return [for (final item in _objects(json, kind)) FileEntry.fromJson(item)];
  });
}

/// What is at [path], following links; absent is an answer, not a refusal.
final class FilesStatOf extends _FilesAt<FileStat> {
  const FilesStatOf(super.path);

  static const String name = 'files.stat';

  @override
  String get kind => name;

  @override
  Object? resultToJson(FileStat result) => result.toJson();

  @override
  FileStat resultFromJson(Object? json) =>
      _decode(kind, () => FileStat.fromJson(_object(json, kind)));
}

/// At most [length] bytes of [path] from [offset] — never more than
/// [kFileChunkBytes] in one answer.
final class FilesRead extends _FilesAt<FileChunk> {
  const FilesRead(super.path, {this.offset = 0, this.length = kFileChunkBytes});

  static const String name = 'files.read';

  final int offset;
  final int length;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ...super.argumentsToJson(),
    'offset': offset,
    'length': length,
  };

  @override
  Object? resultToJson(FileChunk result) => result.toJson();

  @override
  FileChunk resultFromJson(Object? json) =>
      _decode(kind, () => FileChunk.fromJson(_object(json, kind)));
}

/// Replaces [path] with [bytes] if [expect] accepts what is on disk —
/// creating it when [expect] allows absence — and answers the stamp now
/// there. A file that is not what [expect] names is refused `conflict`.
final class FilesWrite extends _FilesAt<FileStamp> {
  const FilesWrite(super.path, this.bytes, {required this.expect});

  static const String name = 'files.write';

  final Uint8List bytes;
  final WriteExpectation expect;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ...super.argumentsToJson(),
    'bytes': base64Encode(bytes),
    'expect': expect.toJson(),
  };

  @override
  Object? resultToJson(FileStamp result) => result.toJson();

  @override
  FileStamp resultFromJson(Object? json) =>
      _decode(kind, () => FileStamp.fromJson(_object(json, kind)));
}

/// Makes the folder [folderName] in [parent]; answers its path. One already
/// there is refused.
final class FilesMkdir extends FilesWorkRequest<EnvironmentPath>
    with _AnswersPath {
  const FilesMkdir(this.parent, this.folderName);

  static const String name = 'files.mkdir';

  final EnvironmentPath parent;
  final String folderName;

  @override
  String get environmentId => parent.environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'parent': environmentPathToJson(parent),
    'name': folderName,
  };
}

/// Makes the empty file [fileName] in [parent]; answers its path. One already
/// there is refused.
final class FilesTouch extends FilesWorkRequest<EnvironmentPath>
    with _AnswersPath {
  const FilesTouch(this.parent, this.fileName);

  static const String name = 'files.touch';

  final EnvironmentPath parent;
  final String fileName;

  @override
  String get environmentId => parent.environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'parent': environmentPathToJson(parent),
    'name': fileName,
  };
}

/// Renames [path] to [newName] in the folder it is already in; answers the
/// new path.
final class FilesRename extends _FilesAt<EnvironmentPath> with _AnswersPath {
  const FilesRename(super.path, this.newName);

  static const String name = 'files.rename';

  final String newName;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ...super.argumentsToJson(),
    'name': newName,
  };
}

/// Deletes [path]; a folder with anything in it only when [recursive].
final class FilesDelete extends _FilesAt<DataAck> with _AnswersAck {
  const FilesDelete(super.path, {this.recursive = false});

  static const String name = 'files.delete';

  final bool recursive;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ...super.argumentsToJson(),
    if (recursive) 'recursive': true,
  };
}

/// Copies the file [source] into the folder [toDirectory] — on the same
/// machine or another the server reaches — keeping its name, or taking
/// [fileName]. Answers where it landed.
final class FilesCopy extends FilesWorkRequest<EnvironmentPath>
    with _AnswersPath {
  const FilesCopy(this.source, this.toDirectory, {this.fileName});

  static const String name = 'files.copy';

  final EnvironmentPath source;
  final EnvironmentPath toDirectory;
  final String? fileName;

  @override
  String get environmentId => toDirectory.environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'source': environmentPathToJson(source),
    'toDirectory': environmentPathToJson(toDirectory),
    'name': ?fileName,
  };
}

/// Every file under the checkout [root], for Quick Open: the server's
/// bounded walk, answered from its cache while that is fresh.
final class FilesIndex extends FilesWorkRequest<RepoFiles> {
  const FilesIndex(this.root);

  static const String name = 'files.index';

  final EnvironmentPath root;

  @override
  String get environmentId => root.environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'root': environmentPathToJson(root),
  };

  @override
  Object? resultToJson(RepoFiles result) => result.toJson();

  @override
  RepoFiles resultFromJson(Object? json) =>
      _decode(kind, () => RepoFiles.fromJson(_object(json, kind)));
}

/// Tells **this link** — no other — a [FileChanged] each time one of [paths]
/// changes on disk, a file or a folder's listing, until [FilesUnwatch] or the
/// link closes. Answered once the server has seen each path as it stands.
final class FilesWatch extends FilesWorkRequest<DataAck> with _AnswersAck {
  const FilesWatch(this.paths);

  static const String name = 'files.watch';

  final List<EnvironmentPath> paths;

  @override
  String get environmentId => paths.isEmpty ? '' : paths.first.environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'paths': [for (final path in paths) environmentPathToJson(path)],
  };
}

/// Stops [FilesWatch] for [paths] on this link.
final class FilesUnwatch extends FilesWorkRequest<DataAck> with _AnswersAck {
  const FilesUnwatch(this.paths);

  static const String name = 'files.unwatch';

  final List<EnvironmentPath> paths;

  @override
  String get environmentId => paths.isEmpty ? '' : paths.first.environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'paths': [for (final path in paths) environmentPathToJson(path)],
  };
}
