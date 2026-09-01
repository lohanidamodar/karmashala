import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../agents/domain/agent_status.dart';
import '../../sessions/application/decision_recorder.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/domain/session_status.dart';
import '../domain/checkpoint.dart';
import 'checkpoint_providers.dart';

/// Turns "an agent finished a turn" into a checkpoint.
///
/// **Which signal, and why this one.** `SessionEventTypes.sessionCompleted`
/// looks like the right event and is not: it means the session's *process*
/// ended, and it is emitted only by the adapter engine, which no in-app session
/// uses now that every one of them runs in a PTY (Loop 41). The signal that
/// actually means "a turn ended" is the Loop 28 status pipeline settling from
/// [AgentActivityStatus.working] to [AgentActivityStatus.idle] — which is the
/// same transition the notifications feature already calls "finished".
///
/// This watches it through `agentSessionStatusProvider`, a read-only seam in
/// `sessions/`, so nothing in the sessions feature has to know checkpoints
/// exist. That costs one status poll per *running* session while this is alive.
/// The cheaper wiring is a third sink on the notifications watcher, which polls
/// once for everything — a follow-up, and a change to a file this loop was kept
/// out of.
class SessionCheckpointRecorder extends Notifier<int> {
  final _log = AppLogger.named('checkpoints');

  /// Sessions with a capture in flight, so a status flicker cannot start two
  /// `git add -A` runs over the same index.
  final Set<String> _capturing = {};

  @override
  int build() {
    // Re-read the session list when a row appears, goes away or changes
    // status, so a session started after this was built is watched too. A full
    // table scan plus one `ref.listen` per running row, so it must not run for
    // a rename — which is published on a timer by the CLI store sweep.
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

  /// Captures [sessionId]'s working tree now, whatever its status.
  ///
  /// Public so the MCP tool and the UI can ask for one; the turn hook above is
  /// the same call with a different reason.
  /// [decidedBy] and [decidedBySessionId] say who asked, for the decision
  /// record — see [_recordIfChosen]. Null is "not recorded", which is what a
  /// caller that genuinely does not know should pass.
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

  /// Writes a *deliberately marked* checkpoint to the session's decision
  /// record.
  ///
  /// Two conditions, and both are the point. The reason must be
  /// [CheckpointReason.manual] — somebody asked for this one, as opposed to the
  /// turn hook above, which fires on every idle transition and would fill the
  /// record with the fact that time passed. And the label must say something —
  /// "a checkpoint taken with a reason" is the act; a nameless one records that
  /// a snapshot exists, which the checkpoint chain already says perfectly well.
  ///
  /// This is the gap analysis's fourth item: the chain records that a turn
  /// happened, never that a state was *chosen*. A labelled manual capture is
  /// the only signal in the app that says which is which.
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
