import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The checkpoint index as the server keeps it. A session's chain is asked
/// for once and then kept by what the server says (each capture's answer, and
/// another client's), so a capture per turn costs one request.
class CheckpointsData implements CheckpointRecords {
  CheckpointsData(this._client) {
    _listening = _client.evidenceChanges.listen(_onChange);
  }

  final DataClient _client;
  late final StreamSubscription<EvidenceChange> _listening;
  final _sessions = <String, List<Checkpoint>>{};
  final _loading = <String, Future<List<Checkpoint>>>{};
  final _changes = StreamController<String>.broadcast(sync: true);

  /// The session whose checkpoints moved — recorded, relabelled or pruned,
  /// here or at another client.
  Stream<String> get changes => _changes.stream;

  void _onChange(EvidenceChange change) {
    switch (change) {
      case CheckpointRecorded(:final checkpoint):
        final kept = _sessions[checkpoint.sessionId];
        if (kept != null) {
          _sessions[checkpoint.sessionId] = withCheckpoint(kept, checkpoint);
        }
        _told(checkpoint.sessionId);
      case CheckpointsPruned(:final sessionId):
        _sessions.remove(sessionId);
        _told(sessionId);
      default:
        break;
    }
  }

  void _told(String sessionId) {
    if (!_changes.isClosed) _changes.add(sessionId);
  }

  @override
  Future<List<Checkpoint>> forSession(String sessionId) {
    final kept = _sessions[sessionId];
    if (kept != null) return Future.value(kept);
    return _loading[sessionId] ??= _client
        .send(CheckpointsForSession(sessionId))
        .then((reply) => _sessions[sessionId] ??= reply.value)
        .whenComplete(() {
          _loading.remove(sessionId);
        });
  }

  @override
  Future<Checkpoint?> byId(String id) async {
    for (final chain in _sessions.values) {
      for (final c in chain) {
        if (c.id == id) return c;
      }
    }
    return (await _client.send(CheckpointGet(id))).value;
  }

  @override
  Future<Checkpoint> record(Checkpoint checkpoint) =>
      _client.write(CheckpointRecord(checkpoint), domain: DataDomain.evidence);

  @override
  Future<Checkpoint> relabel(String id, String label) =>
      _client.write(CheckpointRelabel(id, label), domain: DataDomain.evidence);

  @override
  Future<void> prune(
    String sessionId, {
    required List<String> dropIds,
    required Map<String, ({String commit, String? parent})> rewritten,
  }) => _client.write(
    CheckpointsPrune(sessionId, dropIds: dropIds, rewritten: rewritten),
    domain: DataDomain.evidence,
  );

  /// The newest [limit] checkpoints across every session, newest first.
  Future<List<Checkpoint>> recent({int limit = 50}) async =>
      (await _client.send(CheckpointsRecent(limit))).value;

  /// The highest turn [sessionId] has checkpointed, or 0.
  Future<int> lastTurn(String sessionId) async =>
      lastCheckpointTurnIn(await forSession(sessionId));

  /// The working trees [sessionId] has checkpoints of, most recent first.
  Future<List<EnvironmentPath>> repositoriesFor(String sessionId) async =>
      checkpointRepositoriesIn(await forSession(sessionId));

  Future<void> dispose() async {
    await _listening.cancel();
    await _changes.close();
  }
}

final checkpointsDataProvider = Provider<CheckpointsData>((ref) {
  final data = CheckpointsData(ref.watch(dataClientProvider));
  ref.onDispose(() => unawaited(data.dispose()));
  return data;
});
