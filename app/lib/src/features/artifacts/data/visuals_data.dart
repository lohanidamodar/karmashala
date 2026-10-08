import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// What agents drew with `visualize`, as the server keeps them. A session's
/// list is asked for once and then kept by what the server tells, so a
/// progress bar moving costs no request.
class VisualsData {
  VisualsData(this._client) {
    _listening = _client.artifactChanges.listen(_onChange);
  }

  final DataClient _client;
  late final StreamSubscription<ArtifactChange> _listening;
  final _sessions = <String, List<SessionVisual>>{};
  final _loading = <String, Future<List<SessionVisual>>>{};
  final _images = <(String, String, int), Uint8List>{};
  final _changes = StreamController<SessionVisual>.broadcast(sync: true);

  /// How many images' bytes are held.
  static const _keepImages = 12;

  /// Each visual as it is drawn or updated.
  Stream<SessionVisual> get changes => _changes.stream;

  void _onChange(ArtifactChange change) {
    if (change is! VisualChanged) return;
    final visual = change.visual;
    final kept = _sessions[visual.sessionId];
    if (kept != null) {
      _sessions[visual.sessionId] = List.unmodifiable(
        [
          for (final v in kept)
            if (v.id != visual.id) v,
          visual,
        ]..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
      );
    }
    if (!_changes.isClosed) _changes.add(visual);
  }

  /// [sessionId]'s visuals, first drawn first. A server too old to keep
  /// any answers with none.
  Future<List<SessionVisual>> forSession(String sessionId) {
    final kept = _sessions[sessionId];
    if (kept != null) return Future.value(kept);
    return _loading[sessionId] ??= _client
        .send(SessionVisualsRead(sessionId))
        .then((reply) => reply.value)
        .catchError(
          (Object _) => const <SessionVisual>[],
          test: (e) => e is DataRefused && e.code == DataRefusalCode.invalid,
        )
        .then((list) => _sessions[sessionId] ??= List.unmodifiable(list))
        .whenComplete(() {
          _loading.remove(sessionId);
        });
  }

  /// The bytes of image visual [id] at [revision], over the data channel.
  Future<Uint8List> image(String sessionId, String id, int revision) async {
    final key = (sessionId, id, revision);
    final held = _images.remove(key);
    if (held != null) return _images[key] = held;
    final out = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final chunk = (await _client.send(
        VisualImageRead(sessionId, id, offset: offset),
      )).value;
      out.add(chunk.bytes);
      offset += chunk.bytes.length;
      if (chunk.bytes.isEmpty || offset >= chunk.fileSize) break;
    }
    final bytes = out.takeBytes();
    _images[key] = bytes;
    while (_images.length > _keepImages) {
      _images.remove(_images.keys.first);
    }
    return bytes;
  }

  Future<void> dispose() async {
    await _listening.cancel();
    await _changes.close();
  }
}

final visualsDataProvider = Provider<VisualsData>((ref) {
  final data = VisualsData(ref.watch(dataClientProvider));
  ref.onDispose(() => unawaited(data.dispose()));
  return data;
});
