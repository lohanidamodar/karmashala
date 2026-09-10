import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/descriptors.dart';
import '../../sessions/application/decision_recorder.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:karmashala_session/session.dart';
import '../domain/checkpoint.dart';
import 'checkpoint_providers.dart';

/// Why [SessionCheckpointRecorder.captureNow] can answer with no checkpoint.
/// Two reasons nothing above can tell apart, so it says both (§19).
const String kNothingToCapture =
    'Nothing has changed since the last checkpoint, or this session has no '
    'repository to checkpoint.';

/// Turns "an agent finished a turn" into a checkpoint, off the Loop 28 status
/// pipeline settling `working` -> `idle`, not `sessionCompleted`.
class SessionCheckpointRecorder extends Notifier<int> {
  final _log = AppLogger.named('checkpoints');

  /// Sessions with a capture in flight, so a status flicker cannot start two
  /// `git add -A` runs over the same index.
  final Set<String> _capturing = {};

  @override
  int build() {
    // Re-read the session list when a row appears, goes or changes status. A full
    // scan plus a listen per running row, so it must not run for a rename.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.status,
    });

    final sessions = ref
        .read(sessionDaoProvider)
        .getAll()
        .where((s) => s.status == SessionStatus.running)
        .toList();

    for (final session in sessions) {
      ref.listen(agentSessionStatusProvider(session.id), (previous, next) {
        final before = previous?.value?.status;
        final after = next.value?.status;
        if (before == AgentActivityStatus.working &&
            after == AgentActivityStatus.idle) {
          _capture(session.id);
        }
      });
    }
    return sessions.length;
  }

  /// Captures [sessionId]'s working tree now, whatever its status. [decidedBy]
  /// says who asked; null is "not recorded", which a caller that cannot say passes.
  Future<Checkpoint?> captureNow(
    String sessionId, {
    CheckpointReason reason = CheckpointReason.manual,
    String? label,
    String? decidedBy,
    String? decidedBySessionId,
  }) async {
    final repo = checkpointTargetFor(ref, sessionId);
    if (repo == null) return null;
    if (!_capturing.add(sessionId)) return null;
    try {
      final checkpoint = await ref
          .read(checkpointServiceProvider)
          .capture(repo, sessionId: sessionId, reason: reason, label: label);
      if (checkpoint != null) {
        ref.read(checkpointsRevisionProvider.notifier).bump();
        _recordIfChosen(
          checkpoint,
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
      }
      return checkpoint;
    } catch (error, stack) {
      // A checkpoint that cannot be taken must never stop the turn it was
      // watching. The repository may not be a git repository at all.
      _log.warning('Could not checkpoint session $sessionId.', error, stack);
      return null;
    } finally {
      _capturing.remove(sessionId);
    }
  }

  void _capture(String sessionId) {
    captureNow(sessionId, reason: CheckpointReason.turn);
  }

  /// Writes a *deliberately marked* checkpoint to the decision record: manual
  /// reason and a label, because the chain already records that a turn happened.
  void _recordIfChosen(
    Checkpoint checkpoint, {
    required String? decidedBy,
    required String? decidedBySessionId,
  }) {
    if (checkpoint.reason != CheckpointReason.manual) return;
    final label = checkpoint.label;
    if (label == null || label.trim().isEmpty) return;
    ref
        .read(decisionRecorderProvider)
        .recordCheckpoint(
          sessionId: checkpoint.sessionId,
          checkpointId: checkpoint.id,
          label: label,
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
  }
}

final sessionCheckpointRecorderProvider =
    NotifierProvider<SessionCheckpointRecorder, int>(
      SessionCheckpointRecorder.new,
    );
