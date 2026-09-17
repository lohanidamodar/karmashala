import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/session_status_registry.dart';
import '../../sessions/application/decision_recorder.dart';
import '../domain/checkpoint.dart';
import '../domain/turn_boundary.dart';
import '../data/checkpoint_dao.dart';
import 'checkpoint_providers.dart';
import 'checkpoint_turn_hints.dart';

/// Why [SessionCheckpointRecorder.captureNow] can answer with no checkpoint.
/// Two reasons nothing above can tell apart, so it says both (§19).
const String kNothingToCapture =
    'Nothing has changed since the last checkpoint, or this session has no '
    'repository to checkpoint.';

/// Turns an agent's turns into checkpoints: one as a turn starts (the state
/// to roll back to) and one as it ends, off every status move the registry
/// publishes — hooks first, the grid and transcript where there are none.
class SessionCheckpointRecorder extends Notifier<int> {
  final _log = AppLogger.named('checkpoints');
  final _turns = TurnBoundaryTracker();

  /// One capture at a time per session, queued rather than dropped: a turn's
  /// end must not be lost because its start is still running `git add -A`.
  final Map<String, Future<void>> _queues = {};

  /// The turn in progress per session: its number and prompt, which both of
  /// its checkpoints carry.
  final Map<String, ({int number, String? prompt})> _current = {};

  /// The last turn number handed out per session, kept past the turn: a turn
  /// that changed nothing writes no row for the next number to count from.
  final Map<String, int> _lastTurn = {};

  /// The last skip reason logged per session, so a repeat is not re-logged.
  final Map<String, String> _lastSkip = {};

  StreamSubscription<SessionStatusEntry>? _subscription;
  SessionStatusRegistry? _watching;

  @override
  int build() {
    ref.onDispose(() {
      _subscription?.cancel();
      _subscription = null;
      _watching = null;
    });
    return 0;
  }

  /// Subscribes to the status registry. Idempotent, and called again when the
  /// registry it watched goes away, so a rebuilt registry is not left unwatched.
  void start() {
    if (!ref.mounted) return;
    final SessionStatusRegistry registry;
    try {
      registry = ref.read(sessionStatusRegistryProvider);
    } on Object catch (error, stack) {
      _log.warning('Checkpoint recorder could not start.', error, stack);
      return;
    }
    if (identical(registry, _watching) && _subscription != null) return;
    _subscription?.cancel();
    _watching = registry;
    _subscription = registry.statusChanges.listen(
      _onStatus,
      onError: (Object error, StackTrace stack) =>
          _log.warning('Checkpoint recorder stream failed.', error, stack),
      onDone: () {
        _subscription = null;
        _watching = null;
        // The registry was disposed: a rebuilt one, or the app quitting.
        scheduleMicrotask(start);
      },
    );
    _log.info('Checkpoint recorder is watching agent turns.');
  }

  void _onStatus(SessionStatusEntry entry) {
    // Runs inside the registry's cycle or hook callback: never throw into it.
    try {
      if (entry.session.imported) return;
      final sessionId = entry.session.openId;
      final edge = _turns.observe(sessionId, entry.report.status);
      if (edge == null) return;
      unawaited(_serial(sessionId, () => _captureTurn(sessionId, edge)));
    } on Object catch (error, stack) {
      _log.warning('Checkpoint recorder skipped a status move.', error, stack);
    }
  }

  Future<void> _captureTurn(String sessionId, TurnEdge edge) async {
    if (!ref.mounted) return;
    final reason = edge == TurnEdge.started
        ? CheckpointReason.turnStart
        : CheckpointReason.turn;
    final turn = edge == TurnEdge.started
        ? _beginTurn(sessionId)
        : _current.remove(sessionId) ?? _beginTurn(sessionId);
    final when = edge == TurnEdge.started
        ? 'before turn ${turn.number}'
        : 'after turn ${turn.number}';
    final repo = checkpointTargetFor(ref, sessionId);
    if (repo == null) {
      _skip(sessionId, 'it has no repository to checkpoint');
      return;
    }
    try {
      final checkpoint = await ref
          .read(checkpointServiceProvider)
          .capture(
            repo,
            sessionId: sessionId,
            reason: reason,
            turn: turn.number,
            prompt: turn.prompt,
          );
      if (!ref.mounted) return;
      if (checkpoint == null) {
        _log.info(
          'Checkpoint $when of session $sessionId skipped: '
          '${repo.path} is unchanged since its last checkpoint.',
        );
        return;
      }
      _lastSkip.remove(sessionId);
      ref.read(checkpointsRevisionProvider.notifier).bump();
      _log.info(
        'Checkpoint ${checkpoint.sequence} $when of session $sessionId: '
        '${checkpoint.files.length} files in ${repo.path}.',
      );
    } on Object catch (error) {
      _skip(sessionId, 'capturing ${repo.path} failed: $error');
    }
  }

  ({int number, String? prompt}) _beginTurn(String sessionId) {
    final last = _lastTurn[sessionId] ?? 0;
    final stored = ref.read(checkpointDaoProvider).lastTurn(sessionId);
    final ({int number, String? prompt}) turn = (
      number: (last > stored ? last : stored) + 1,
      prompt: ref.read(checkpointTurnHintsProvider).takePrompt(sessionId),
    );
    _current[sessionId] = turn;
    _lastTurn[sessionId] = turn.number;
    return turn;
  }

  void _skip(String sessionId, String reason) {
    if (_lastSkip[sessionId] == reason) return;
    _lastSkip[sessionId] = reason;
    _log.info('No checkpoint for session $sessionId: $reason.');
  }

  Future<T> _serial<T>(String sessionId, Future<T> Function() task) {
    final previous = _queues[sessionId] ?? Future<void>.value();
    final result = previous.then((_) => task());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _queues[sessionId] = tail;
    tail.whenComplete(() {
      if (identical(_queues[sessionId], tail)) _queues.remove(sessionId);
    });
    return result;
  }

  /// Captures [sessionId]'s working tree now, whatever its status. [decidedBy]
  /// says who asked; null is "not recorded", which a caller that cannot say passes.
  Future<Checkpoint?> captureNow(
    String sessionId, {
    CheckpointReason reason = CheckpointReason.manual,
    String? label,
    String? decidedBy,
    String? decidedBySessionId,
  }) {
    return _serial(sessionId, () async {
      final repo = checkpointTargetFor(ref, sessionId);
      if (repo == null) return null;
      try {
        final checkpoint = await ref
            .read(checkpointServiceProvider)
            .capture(repo, sessionId: sessionId, reason: reason, label: label);
        if (checkpoint != null && ref.mounted) {
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
      }
    });
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
