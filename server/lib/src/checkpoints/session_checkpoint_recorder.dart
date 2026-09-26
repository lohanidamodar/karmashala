import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_store/database.dart';

import 'checkpoint_targets.dart';
import 'checkpoint_turn_hints.dart';

typedef _Turn = ({int number, String? prompt});

/// **Turns an agent's turns into checkpoints, at the server**: one as a turn
/// starts (the state to roll back to) and one as it ends, off each status
/// move it is given ([observe]) — the daemon's own status for sessions it
/// holds, the hook's word for rows on this machine it does not. Captures run
/// one at a time per session, queued rather than dropped: a turn's end must
/// not be lost because its start is still running `git add -A`.
///
/// Every row it writes reaches clients as a change (the service's records
/// are the store's, told as they write), and so does why a session has no
/// automatic checkpoints right now ([skipReasons]).
class ServerCheckpointRecorder {
  ServerCheckpointRecorder({
    required this.database,
    required this.service,
    required this.targets,
    required this.hints,
    required void Function(List<DataChange> changes) tell,
    required Future<void> Function(DecisionRecord decision) fileDecision,
    DateTime Function()? clock,
    void Function(String message)? log,
  }) : _tell = tell,
       _fileDecision = fileDecision,
       _now = clock ?? _utcNow,
       _log = log ?? _silent;

  final AppDatabase database;
  final CheckpointService service;
  final ServerCheckpointTargets targets;
  final CheckpointTurnHints hints;
  final void Function(List<DataChange> changes) _tell;
  final Future<void> Function(DecisionRecord decision) _fileDecision;
  final DateTime Function() _now;
  final void Function(String message) _log;

  final _turns = TurnBoundaryTracker();
  final Map<String, Future<void>> _queues = {};

  /// The turn in progress per session, which all of its checkpoints carry.
  final Map<String, _Turn> _current = {};

  /// The last turn number handed out per session, kept past the turn: a turn
  /// that changed nothing writes no row for the next number to count from.
  final Map<String, int> _lastTurn = {};

  /// The repositories already given a before-turn checkpoint this turn.
  final Map<String, Set<String>> _startedIn = {};

  /// The sessions whose tool was released this turn before their before-turn
  /// snapshot was confirmed taken. See [noteHoldExpired], [noteToolUnheld].
  final Set<String> _released = {};

  /// The last message logged per session and repository, so a repeat is not.
  final Map<String, String> _lastLogged = {};

  final Map<String, String> _skips = {};

  var _closed = false;

  static DateTime _utcNow() => DateTime.now().toUtc();
  static void _silent(String _) {}

  CheckpointDao get _dao => targets.checkpoints;

  /// Why each session has no automatic checkpoints right now.
  Map<String, String> get skipReasons => Map.unmodifiable(_skips);

  /// The settings a client last wrote, read each time: a change needs no
  /// notice to reach the next turn.
  CheckpointSettings get settings {
    final raw = database.readMetadata(kCheckpointSettingsKey);
    if (raw == null) return const CheckpointSettings();
    try {
      return CheckpointSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const CheckpointSettings();
    }
  }

  /// Whether [sessionId] is inside a turn, as the edges seen so far say.
  bool inTurn(String sessionId) => _turns.inTurn(sessionId);

  /// One status move of the session row [sessionId]. Never throws: it runs
  /// inside whatever published the status.
  void observe(String sessionId, AgentActivityStatus status) {
    if (_closed) return;
    try {
      final edge = _turns.observe(sessionId, status);
      if (edge == null) return;
      // Here rather than inside the capture, because a capture is queued and a
      // hold can give up while it waits: reset at the moment the turn begins
      // and no hold of *this* turn can be forgotten, and none of the last
      // turn's can be inherited.
      if (edge == TurnEdge.started) _released.remove(sessionId);
      unawaited(_serial(sessionId, () => _captureTurn(sessionId, edge)));
    } on Object catch (error) {
      _log('checkpoint recorder skipped a status move of $sessionId: $error');
    }
  }

  /// Completes when [sessionId]'s queued captures have, so a hook about to let
  /// a tool write can hold it until the before-turn checkpoint exists.
  ///
  /// **The wait for the queue to be joined is the point.** A turn's edge can
  /// be queued a few event-loop turns after the hook that caused it arrived
  /// (the status is published, then heard), so a hold that asks at once can
  /// find an empty queue and let the tool run — and the before-turn snapshot
  /// is then taken of a tree the tool already edited. A timer tick runs after
  /// every pending microtask, so what was published has been queued by the
  /// time the queue is read; the second pass covers a capture that queues
  /// another.
  Future<void> settled(String sessionId) async {
    var quiet = 0;
    for (var pass = 0; pass < _settlePasses && quiet < _settleQuiet; pass++) {
      await Future<void>.delayed(Duration.zero);
      final queued = _queues[sessionId];
      if (queued == null) {
        quiet++;
        continue;
      }
      quiet = 0;
      await queued;
    }
  }

  static const int _settleQuiet = 3;
  static const int _settlePasses = 24;

  /// A `PreToolUse` hold gave up: [sessionId]'s tool was released before its
  /// before-turn snapshot was confirmed taken.
  ///
  /// **The hold is bounded and the bound is not ours to lift.** It has to fit
  /// inside the two seconds the installed hook script gives `curl`, and a wait
  /// longer than that does not hold the tool — `curl` dies and the agent
  /// carries on. So every before-turn checkpoint this turn writes afterwards
  /// *may* be of a tree the tool already edited, and says so on its own row.
  /// Reset as the next turn begins.
  void noteHoldExpired(String sessionId) =>
      _release(sessionId, 'its hold expired');

  /// A `PreToolUse` reached the server with no request to hold — a client
  /// took it on its own route or from a spool and forwarded it: the tool it
  /// announces ran before this was read. The same mark as [noteHoldExpired].
  void noteToolUnheld(String sessionId) => _release(
    sessionId,
    'its hook was answered before anything could hold it',
  );

  void _release(String sessionId, String why) {
    if (!_released.add(sessionId)) return;
    _log(
      'session $sessionId released a tool before its before-turn checkpoint '
      'was taken ($why): this turn may have no undo point taken before its '
      'first edit',
    );
  }

  /// A hook named a new path mid-turn: a repository it is in that has no
  /// before-turn checkpoint yet gets one now, before the tool runs.
  void noteTouched(String sessionId) {
    if (_closed || !_turns.inTurn(sessionId)) return;
    unawaited(
      _serial(sessionId, () async {
        final turn = _current[sessionId];
        if (turn == null) return;
        final found = await targets.of(
          sessionId,
          touched: hints.pathsOf(sessionId),
          cwd: hints.cwdOf(sessionId),
        );
        final started = _startedIn[sessionId] ??= <String>{};
        for (final repo in found) {
          if (!started.add(_keyOf(repo))) continue;
          await _captureOne(
            sessionId,
            repo,
            CheckpointReason.turnStart,
            turn,
            'before turn ${turn.number} first changed it',
          );
        }
      }),
    );
  }

  Future<void> _captureTurn(String sessionId, TurnEdge edge) async {
    if (_closed) return;
    final starting = edge == TurnEdge.started;
    final settings = this.settings;
    if (!settings.automatic) {
      _skip(sessionId, kAutomaticCheckpointsOff);
      return;
    }
    final turn = starting
        ? _beginTurn(sessionId)
        : _current.remove(sessionId) ?? _beginTurn(sessionId);
    final found = await targets.of(
      sessionId,
      touched: hints.pathsOf(sessionId),
      cwd: hints.cwdOf(sessionId),
    );
    if (!starting) {
      hints.clearPaths(sessionId);
      _startedIn.remove(sessionId);
    }
    if (found.isEmpty) {
      _skip(sessionId, 'it has no repository to checkpoint');
      return;
    }
    final started = starting ? (_startedIn[sessionId] = <String>{}) : null;
    for (final repo in found) {
      started?.add(_keyOf(repo));
      await _captureOne(
        sessionId,
        repo,
        starting ? CheckpointReason.turnStart : CheckpointReason.turn,
        turn,
        starting ? 'before turn ${turn.number}' : 'after turn ${turn.number}',
      );
    }
    final keep = settings.keepPerRepository;
    if (!starting && keep != null) {
      for (final repo in found) {
        await _prune(sessionId, repo, keep);
      }
    }
  }

  Future<void> _captureOne(
    String sessionId,
    EnvironmentPath repo,
    CheckpointReason reason,
    _Turn turn,
    String when,
  ) async {
    if (_closed) return;
    final unsupported = service.unsupportedReason(repo);
    if (unsupported != null) {
      _skip(sessionId, unsupported, repo: repo);
      return;
    }
    try {
      final checkpoint = await service.capture(
        repo,
        sessionId: sessionId,
        reason: reason,
        turn: turn.number,
        prompt: turn.prompt,
      );
      _clearSkip(sessionId);
      _lastLogged.remove(_logKey(sessionId, repo));
      if (checkpoint == null) return;
      // **Asked now, not before the capture.** What makes a before-turn
      // snapshot untrustworthy is the tool having been released *by the time
      // it was taken* — and the hold can give up while this very capture is
      // running `git add -A`. A row written before the give-up is genuinely
      // before the edit and is left alone.
      if (reason == CheckpointReason.turnStart &&
          _released.contains(sessionId)) {
        await service.records.relabel(
          checkpoint.id,
          lateTurnStartLabel(turn.number),
        );
      }
    } on Object catch (error) {
      _skip(sessionId, 'capturing ${repo.path} failed: $error', repo: repo);
    }
  }

  /// Prunes in batches, so a session at its limit does not re-commit the whole
  /// chain on every turn.
  Future<void> _prune(String sessionId, EnvironmentPath repo, int keep) async {
    final count = checkpointChainIn(_dao.forSession(sessionId), repo).length;
    if (count <= keep + checkpointPruneSlack(keep) || _closed) return;
    try {
      final dropped = await service.prune(
        repo,
        sessionId: sessionId,
        keep: keep,
      );
      _log(
        'pruned $dropped checkpoints of session $sessionId in ${repo.path}, '
        'keeping the newest $keep',
      );
    } on Object catch (error) {
      _log('could not prune checkpoints of ${repo.path}: $error');
    }
  }

  _Turn _beginTurn(String sessionId) {
    final last = _lastTurn[sessionId] ?? 0;
    final stored = _dao.lastTurn(sessionId);
    final _Turn turn = (
      number: (last > stored ? last : stored) + 1,
      prompt: hints.takePrompt(sessionId),
    );
    _current[sessionId] = turn;
    _lastTurn[sessionId] = turn.number;
    return turn;
  }

  void _skip(String sessionId, String reason, {EnvironmentPath? repo}) {
    if (_skips[sessionId] != reason) {
      _skips[sessionId] = reason;
      _tell([CheckpointSkipChanged(sessionId, reason)]);
    }
    final key = _logKey(sessionId, repo);
    if (_lastLogged[key] == reason) return;
    _lastLogged[key] = reason;
    _log('no checkpoint for session $sessionId: $reason');
  }

  void _clearSkip(String sessionId) {
    if (_skips.remove(sessionId) == null) return;
    _tell([CheckpointSkipChanged(sessionId, null)]);
  }

  static String _keyOf(EnvironmentPath repo) =>
      '${repo.environmentId} ${repo.path}';

  static String _logKey(String sessionId, EnvironmentPath? repo) =>
      repo == null ? sessionId : '$sessionId ${_keyOf(repo)}';

  /// Runs [task] in [sessionId]'s queue, after every capture queued before
  /// it: git work on one checkout's private index, one at a time.
  Future<T> queued<T>(String sessionId, Future<T> Function() task) =>
      _serial(sessionId, task);

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

  /// Captures [sessionId]'s working trees now, whatever its status, through
  /// its queue, answering with the first checkpoint taken — its own
  /// checkout's when that moved. A [label]led one is filed to the decision
  /// record as decided by [decidedBy] (null: not recorded).
  Future<Checkpoint?> captureNow(
    String sessionId, {
    String? label,
    String? decidedBy,
    String? decidedBySessionId,
  }) {
    return _serial(sessionId, () async {
      final found = await targets.of(sessionId, cwd: hints.cwdOf(sessionId));
      Checkpoint? first;
      for (final repo in found) {
        try {
          final checkpoint = await service.capture(
            repo,
            sessionId: sessionId,
            reason: CheckpointReason.manual,
            label: label,
          );
          if (checkpoint == null) continue;
          first ??= checkpoint;
          _recordIfChosen(
            checkpoint,
            decidedBy: decidedBy,
            decidedBySessionId: decidedBySessionId,
          );
        } on Object catch (error) {
          // A checkpoint that cannot be taken must never stop anything else.
          // The repository may not be a git repository at all.
          _log('could not checkpoint ${repo.path} for $sessionId: $error');
        }
      }
      return first;
    });
  }

  /// Writes a *deliberately marked* checkpoint to the decision record: manual
  /// reason and a label, because the chain already records that a turn
  /// happened.
  void _recordIfChosen(
    Checkpoint checkpoint, {
    required String? decidedBy,
    required String? decidedBySessionId,
  }) {
    if (checkpoint.reason != CheckpointReason.manual) return;
    final label = checkpoint.label;
    if (label == null || label.trim().isEmpty) return;
    unawaited(
      _fileDecision(
        DecisionRecord(
          sessionId: checkpoint.sessionId,
          kind: DecisionKind.checkpointMarked,
          summary: label.trim(),
          decidedBy: decidedBy,
          recordedBySessionId: decidedBySessionId,
          origin: DecisionOrigin.checkpoint,
          originId: checkpoint.id,
          recordedAt: _now(),
        ),
      ).catchError((Object error) {
        _log(
          'could not file checkpoint ${checkpoint.id} as a decision: $error',
        );
      }),
    );
  }

  /// Completes once every queued capture has; nothing new starts after.
  Future<void> close() async {
    _closed = true;
    await Future.wait([..._queues.values]);
  }
}
