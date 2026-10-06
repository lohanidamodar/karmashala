import 'dart:async';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_artifacts/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/karmashala_files.dart';
import 'package:karmashala_store/database.dart';

/// What answers the artifact requests a client asks of the server.
abstract interface class ArtifactsWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(ArtifactsRequest<Object?> request);
}

/// **What agents showed in their threads, for every client.** The library
/// keeps each revision's snapshot under the server's data folder, the
/// watcher re-reads a source that changes on its host, and every change is
/// told to every client — none of whom is ever handed a host path.
class ServerArtifacts implements ArtifactsWork {
  ServerArtifacts({
    required this.library,
    required this.watcher,
    required void Function(List<DataChange> changes) tell,
  }) {
    library.onChanged = (artifact) => tell([ArtifactChanged(artifact)]);
  }

  /// The library over [database], snapshots in [directory], sources read
  /// through [spaceFor] — the server's file spaces, so a WSL or SSH session's
  /// file is read where it was written.
  factory ServerArtifacts.over({
    required AppDatabase database,
    required String directory,
    required FileSpace? Function(String environmentId) spaceFor,
    required void Function(List<DataChange> changes) tell,
    bool Function(String environmentId)? isRemote,
  }) {
    final sources = ServerArtifactSources(spaceFor);
    final library = ArtifactLibrary(
      dao: ArtifactDao(database),
      directory: directory,
      sources: sources,
    );
    return ServerArtifacts(
      library: library,
      watcher: ArtifactWatcher(
        library,
        sources: sources,
        intervalOf: (id) => isRemote?.call(id) ?? false
            ? const Duration(seconds: 5)
            : const Duration(seconds: 1),
      ),
      tell: tell,
    );
  }

  final ArtifactLibrary library;
  final ArtifactWatcher watcher;

  void start() => watcher.start();

  void close() => watcher.stop();

  @override
  Future<Object?> handle(ArtifactsRequest<Object?> request) async {
    switch (request) {
      case SessionArtifactsRead(:final sessionId):
        return library.forSession(sessionId);
      case ArtifactRevisionsRead(:final id):
        _known(id);
        return [
          for (final r in library.revisions(id)) ArtifactRevisionSummary.of(r),
        ];
      case ArtifactContentRead(
        :final id,
        :final revision,
        :final offset,
        :final length,
      ):
        _known(id);
        if (offset < 0 || length < 0) {
          throw const DataRefused.invalid('artifacts.content: a negative range');
        }
        final Uint8List bytes;
        try {
          bytes = await library.content(id, revision: revision);
        } on StateError catch (error) {
          throw DataRefused.notFound(error.message);
        }
        final start = offset > bytes.length ? bytes.length : offset;
        final want = length > kFileChunkBytes ? kFileChunkBytes : length;
        final end = start + want > bytes.length ? bytes.length : start + want;
        return FileChunk(
          Uint8List.sublistView(bytes, start, end),
          fileSize: bytes.length,
        );
      case ArtifactSetNetwork(:final id, :final allowed):
        _known(id);
        return library.update(id, networkAllowed: allowed);
    }
  }

  void _known(String id) {
    if (library.byId(id) == null) {
      throw DataRefused.notFound('no artifact has id $id');
    }
  }
}

/// A session's host files, read through the server's own file spaces.
class ServerArtifactSources implements ArtifactSources {
  ServerArtifactSources(this._spaceFor);

  final FileSpace? Function(String environmentId) _spaceFor;

  FileSpace _space(EnvironmentPath path) =>
      _spaceFor(path.environmentId) ??
      (throw StateError(
        'this server cannot reach files in "${path.environmentId}"',
      ));

  @override
  Future<ArtifactSourceStat> stat(EnvironmentPath path) async {
    final stat = await _space(path).stat(path);
    if (!stat.exists || stat.isDirectory) {
      return const ArtifactSourceStat.absent();
    }
    return ArtifactSourceStat(size: stat.size, modified: stat.stamp?.modified);
  }

  @override
  Future<Uint8List> read(EnvironmentPath path) => _space(path).read(path);
}
