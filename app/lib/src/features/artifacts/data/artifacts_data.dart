import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// What agents showed in their threads, as the server keeps them. A session's
/// list is asked for once and then kept by what the server tells, so a
/// revision costs no request until a view wants its bytes. Content always
/// comes over the data channel — on this machine or a phone over the relay
/// alike — and never from a host path.
class ArtifactsData {
  ArtifactsData(this._client) {
    _listening = _client.artifactChanges.listen(_onChange);
  }

  final DataClient _client;
  late final StreamSubscription<ArtifactChange> _listening;
  final _sessions = <String, List<Artifact>>{};
  final _loading = <String, Future<List<Artifact>>>{};
  final _content = <(String, int), Uint8List>{};
  final _changes = StreamController<Artifact>.broadcast(sync: true);

  /// How many revisions' bytes are held; a viewer re-asks past it.
  static const _keepContent = 12;

  /// Each artifact as it is shown, revised or found missing.
  Stream<Artifact> get changes => _changes.stream;

  void _onChange(ArtifactChange change) {
    switch (change) {
      case ArtifactChanged(:final artifact):
        final kept = _sessions[artifact.sessionId];
        if (kept != null) {
          _sessions[artifact.sessionId] = _with(kept, artifact);
        }
        if (!_changes.isClosed) _changes.add(artifact);
    }
  }

  static List<Artifact> _with(List<Artifact> kept, Artifact artifact) {
    final next = [
      for (final a in kept)
        if (a.id != artifact.id) a,
      artifact,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return List.unmodifiable(next);
  }

  /// [sessionId]'s artifacts, oldest first. A server too old to keep any
  /// answers with none.
  Future<List<Artifact>> forSession(String sessionId) {
    final kept = _sessions[sessionId];
    if (kept != null) return Future.value(kept);
    return _loading[sessionId] ??= _client
        .send(SessionArtifactsRead(sessionId))
        .then((reply) => reply.value)
        .catchError(
          (Object _) => const <Artifact>[],
          test: (e) => e is DataRefused && e.code == DataRefusalCode.invalid,
        )
        .then((list) => _sessions[sessionId] ??= List.unmodifiable(list))
        .whenComplete(() {
          _loading.remove(sessionId);
        });
  }

  /// [sessionId]'s artifacts as held now — none until its list has been read,
  /// which this starts — for a caller that cannot wait, as quick open.
  List<Artifact> held(String sessionId) {
    final kept = _sessions[sessionId];
    if (kept == null) unawaited(forSession(sessionId).then((_) {}, onError: (_) {}));
    return kept ?? const [];
  }

  /// The artifact [id] as last told, if its session's list is held.
  Artifact? cached(String id) {
    for (final list in _sessions.values) {
      for (final a in list) {
        if (a.id == id) return a;
      }
    }
    return null;
  }

  Future<List<ArtifactRevisionSummary>> revisions(String id) async =>
      (await _client.send(ArtifactRevisionsRead(id))).value;

  /// The bytes of [id] at [revision], in 1 MiB answers. Throws the server's
  /// [DataRefused] when it cannot serve them.
  Future<Uint8List> content(String id, int revision) async {
    final key = (id, revision);
    final held = _content.remove(key);
    if (held != null) return _content[key] = held;
    final out = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final chunk = (await _client.send(
        ArtifactContentRead(id, revision: revision, offset: offset),
      )).value;
      out.add(chunk.bytes);
      offset += chunk.bytes.length;
      if (chunk.bytes.isEmpty || offset >= chunk.fileSize) break;
    }
    final bytes = out.takeBytes();
    _content[key] = bytes;
    while (_content.length > _keepContent) {
      _content.remove(_content.keys.first);
    }
    return bytes;
  }

  /// Lets [id] reach the network, or takes it back, for every client.
  Future<Artifact> setNetwork(String id, {required bool allowed}) async =>
      (await _client.send(ArtifactSetNetwork(id, allowed: allowed))).value;

  Future<void> dispose() async {
    await _listening.cancel();
    await _changes.close();
  }
}

final artifactsDataProvider = Provider<ArtifactsData>((ref) {
  final data = ArtifactsData(ref.watch(dataClientProvider));
  ref.onDispose(() => unawaited(data.dispose()));
  return data;
});
