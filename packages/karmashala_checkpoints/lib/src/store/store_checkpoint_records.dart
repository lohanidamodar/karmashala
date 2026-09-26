import '../domain/checkpoint.dart';
import '../service/checkpoint_records.dart';
import 'checkpoint_dao.dart';

/// [CheckpointRecords] straight over the store, for the server; [onRecorded]
/// and [onPruned] hear what it wrote.
class StoreCheckpointRecords implements CheckpointRecords {
  StoreCheckpointRecords(this._dao, {this.onRecorded, this.onPruned});

  final CheckpointDao _dao;
  final void Function(Checkpoint checkpoint)? onRecorded;
  final void Function(String sessionId)? onPruned;

  @override
  Future<List<Checkpoint>> forSession(String sessionId) async =>
      _dao.forSession(sessionId);

  @override
  Future<Checkpoint?> byId(String id) async => _dao.getById(id);

  @override
  Future<Checkpoint> record(Checkpoint checkpoint) async {
    final stored = _dao.insert(checkpoint);
    onRecorded?.call(stored);
    return stored;
  }

  @override
  Future<Checkpoint> relabel(String id, String label) async {
    _dao.relabel(id, label);
    final stored = _dao.getById(id)!;
    onRecorded?.call(stored);
    return stored;
  }

  @override
  Future<void> prune(
    String sessionId, {
    required List<String> dropIds,
    required Map<String, ({String commit, String? parent})> rewritten,
  }) async {
    _dao.prune(dropIds: dropIds, rewritten: rewritten);
    onPruned?.call(sessionId);
  }
}
