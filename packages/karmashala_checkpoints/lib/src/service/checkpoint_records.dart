import '../domain/checkpoint.dart';

/// Where [CheckpointService] keeps the index over its git objects: the store
/// at the server, the server's data API in a client.
abstract interface class CheckpointRecords {
  /// Every checkpoint of [sessionId], oldest first.
  Future<List<Checkpoint>> forSession(String sessionId);

  Future<Checkpoint?> byId(String id);

  /// Records [checkpoint] and answers it with the sequence the store gave it.
  Future<Checkpoint> record(Checkpoint checkpoint);

  Future<Checkpoint> relabel(String id, String label);

  /// Drops [dropIds] of [sessionId] and re-points the survivors at their
  /// rewritten commits, in one step.
  Future<void> prune(
    String sessionId, {
    required List<String> dropIds,
    required Map<String, ({String commit, String? parent})> rewritten,
  });
}
