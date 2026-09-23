import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import 'session_launcher.dart';
import 'session_notice.dart';

/// Model changes made while a session was mid-turn, applied the moment it is
/// at its prompt again rather than on its next launch. Keyed by session; a
/// second pick replaces the first, and only the model *recorded then* is sent.
class PendingLiveSwitches {
  /// [becameIdle] names each session the moment its status moves to idle.
  PendingLiveSwitches(this._ref, Stream<String> becameIdle) {
    _moves = becameIdle.listen(_apply);
  }

  final Ref _ref;
  late final StreamSubscription<Object?> _moves;
  final Set<String> _waiting = <String>{};

  /// Whether [sessionId] has a change waiting for its turn to end.
  bool holds(String sessionId) => _waiting.contains(sessionId);

  void hold(String sessionId) => _waiting.add(sessionId);

  void _apply(String sessionId) {
    if (!_waiting.remove(sessionId)) return;
    final launcher = _ref.read(sessionLauncherProvider);
    // Read again now: the pick may have been handed back to the default, or the
    // session relaunched on the new model, since it was held.
    final outcome = launcher.switchModelNow(sessionId);
    if (outcome == null) return;
    _ref
        .read(sessionNoticesProvider.notifier)
        .post(
          sessionId,
          SessionNotice(
            message:
                'The turn ended — switched now: "$outcome" was sent to the '
                'session.',
          ),
        );
  }

  void dispose() => unawaited(_moves.cancel());
}

/// Watched from the shell, like the liveness reconciler: an unwatched provider
/// hears no status move.
final pendingLiveSwitchesProvider = Provider<PendingLiveSwitches>((ref) {
  final switches = PendingLiveSwitches(
    ref,
    ref
        .read(sessionStatusRegistryProvider)
        .statusChanges
        .where((entry) => entry.report.status == AgentActivityStatus.idle)
        .map((entry) => entry.session.openId),
  );
  ref.onDispose(switches.dispose);
  return switches;
});
