import 'package:karmashala_checkpoints/checkpoints.dart'
    show
        Checkpoint,
        CheckpointConflict,
        CheckpointRestoreAnswer,
        RestorePreview;

import '../../checkpoints/daemon_checkpoints.dart';
import 'session_rewinds.dart';

/// A rewind's files over the server's checkpoints: the checkpoints a fork
/// from the same turn would restore, refused for the same reasons.
class DaemonRewindFiles implements RewindFiles {
  DaemonRewindFiles(this.checkpoints);

  final DaemonCheckpoints checkpoints;

  @override
  List<Checkpoint> checkpointsFor({
    required String sessionId,
    String? checkpointId,
    int? turn,
  }) => checkpoints.forkCheckpoints(
    sessionId: sessionId,
    checkpointId: checkpointId,
    turn: turn,
  );

  @override
  String? refusal(Checkpoint checkpoint, {required String sessionId}) =>
      checkpoints.forkFileRefusal(
        checkpoint,
        sessionId: sessionId,
        intoNewWorktree: false,
      );

  @override
  Future<RestorePreview> preview(Checkpoint checkpoint) =>
      checkpoints.restorePreview(checkpoint);

  @override
  Future<CheckpointConflict?> conflict(Checkpoint checkpoint) =>
      checkpoints.forkConflict(checkpoint);

  @override
  Future<CheckpointRestoreAnswer> restore(
    Checkpoint checkpoint, {
    required bool confirm,
  }) => checkpoints.restore(checkpoint, confirm: confirm);
}
