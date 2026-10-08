import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_git/git.dart' show HunkSelection;
import 'package:karmashala_git/repositories.dart' show samePath;
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import '../data/data_service.dart';
import '../domain/uuid.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'checkpoint_targets.dart';
import 'checkpoint_turn_hints.dart';
import 'session_checkpoint_recorder.dart';

/// The hook events whose agent is held until its turn's before-turn
/// checkpoint exists: a `PreToolUse`, so the tool it announces cannot change
/// files first.
const Set<String> kHeldHookEvents = {'PreToolUse'};

/// The longest a tool's hook is held for its before-turn checkpoint: inside
/// the two seconds the installed hook scripts give `curl` (`-m 2`), with room
/// for the answer. Holding longer does not hold the tool — `curl` dies and
/// the agent carries on — so an expired hold marks the turn instead.
const Duration kCheckpointHookHold = Duration(milliseconds: 1500);

/// **Per-turn checkpoints, kept by the server** (slice 2b): the recorder, the
/// hook intake that feeds it and holds a `PreToolUse` for it, the checkpoint
/// work a client asks for ([handle]: capture, a run's base, diff, restore,
/// skip reasons), the reads the agent tools answer from, and the fork
/// primitive. Every row it writes is told to every client through [data].
class DaemonCheckpoints {
  DaemonCheckpoints({
    required AppDatabase database,
    required this.data,
    required bool Function(String sessionId) heldHere,
    bool Function(String sessionId, String conversationId)? ownsConversation,
    CommandRunnerFactory runnerFactory = const CommandRunnerFactory(),
    this.agents = AgentRegistry.builtIn,
    DateTime Function()? clock,
    String Function()? newId,
    this.hold = kCheckpointHookHold,
    bool Function(EnvironmentPath directory)? present,
    void Function(String message)? log,
  }) : _heldHere = heldHere,
       _ownsConversation = ownsConversation,
       _sessions = SessionDao(database),
       _repositories = RepositoryDao(database),
       _dao = CheckpointDao(database),
       _log = log ?? _silent {
    final now = clock ?? _utcNow;
    final environments = ExecutionEnvironmentDao(database);
    service = CheckpointService(
      runnerFactory: runnerFactory,
      environmentOf: environments.getById,
      records: StoreCheckpointRecords(
        _dao,
        onRecorded: (c) => data.announce([CheckpointRecorded(c)]),
        onPruned: (sessionId) => data.announce([CheckpointsPruned(sessionId)]),
      ),
      clock: _FunctionClock(now),
      newId: newId ?? newUuid,
    );
    _decisions = data.open(_ignore);
    recorder = ServerCheckpointRecorder(
      database: database,
      service: service,
      targets: ServerCheckpointTargets(
        sessions: _sessions,
        repositories: _repositories,
        environments: environments,
        checkpoints: _dao,
        service: service,
        present: present,
      ),
      hints: hints,
      tell: data.announce,
      fileDecision: (decision) async =>
          _decisions.handle(DecisionAppend(decision)),
      clock: now,
      log: _log,
    );
    _classifier = HostedStatusKeeper(
      agents: agents,
      clock: _FunctionClock(now),
    );
  }

  final DataService data;
  final AgentRegistry agents;

  /// How long a `PreToolUse` is held; [kCheckpointHookHold] but in tests.
  final Duration hold;
  final bool Function(String sessionId) _heldHere;

  /// Whether a hook in a held pane about a conversation is that pane's
  /// agent's (`DaemonAgentStatus.ownsConversation`); null believes the pane.
  final bool Function(String sessionId, String conversationId)?
  _ownsConversation;
  final SessionDao _sessions;
  final RepositoryDao _repositories;
  final CheckpointDao _dao;
  final void Function(String message) _log;
  final hints = CheckpointTurnHints();
  late final CheckpointService service;
  late final ServerCheckpointRecorder recorder;
  late final DataSession _decisions;

  /// Reads a hook's word with its agent's adapter, for rows this server does
  /// not hold (whose status nobody here keeps); never keeps a status itself.
  late final HostedStatusKeeper _classifier;
  StreamSubscription<HostedAgentStatus>? _statuses;

  static DateTime _utcNow() => DateTime.now().toUtc();
  static void _silent(String _) {}
  static void _ignore(DataChanges _) {}

  /// Hears the daemon's own status for the sessions it holds — their turn
  /// edges. Rows it does not hold are heard through [hook].
  void start(Stream<HostedAgentStatus> statuses) {
    _statuses ??= statuses.listen(
      (status) => recorder.observe(status.sessionId, status.report.status),
    );
  }

  Future<void> close() async {
    await _statuses?.cancel();
    _statuses = null;
    await recorder.close();
    _decisions.close();
  }

  // Hooks.

  /// One hook the server's endpoint took, **before** the daemon's status
  /// folds it in: files its prompt and paths (so the turn it starts is
  /// labelled), moves a row this server does not hold by the hook's word,
  /// and answers when the agent may go on — for a `PreToolUse`, once the
  /// session's queued captures are done, at most [hold]; on expiry the
  /// turn's before-turn checkpoints are marked unverified. Never throws.
  Future<void> hook(AgentHookEvent hook) {
    final sessionId = _intake(hook);
    if (sessionId == null || !kHeldHookEvents.contains(hook.event)) {
      return Future<void>.value();
    }
    return recorder
        .settled(sessionId)
        .timeout(hold, onTimeout: () => recorder.noteHoldExpired(sessionId))
        .catchError((Object error) {
          _log('holding a tool of $sessionId failed: $error');
        });
  }

  /// A hook a WSL agent wrote into its spool, drained by the server
  /// (`HookSpools`, slice 5a): read as [hook] reads one, but never held — its
  /// agent went on long before — so a `PreToolUse` marks the turn's
  /// before-turn checkpoints still to come unverified.
  void spooled(AgentHookEvent hook) {
    final sessionId = _intake(hook);
    if (sessionId == null || !kHeldHookEvents.contains(hook.event)) return;
    // After the edge: a turn this very hook starts has begun, and does not
    // clear the mark.
    recorder.noteToolUnheld(sessionId);
  }

  /// The row [hook] is about, its hints filed and — for a row this server
  /// does not hold — its turn edge observed. Null for a hook no row here
  /// owns.
  String? _intake(AgentHookEvent hook) {
    try {
      final body = jsonEncode(hook.body);
      final report = _classifier.classify(
        agentId: hook.agent,
        event: hook.event,
        body: body,
        receivedAt: hook.receivedAt,
      );
      final sessionId = _rowOf(hook.sessionHeader, report.sessionId);
      if (sessionId == null) return null;
      final spec = agents.byId(hook.agent)?.hooks;
      if (spec != null) {
        final touched = hints.read(
          sessionId,
          spec: spec,
          event: hook.event,
          payload: hook.body,
        );
        if (touched) recorder.noteTouched(sessionId);
      }
      // A row the daemon holds moves by the daemon's own status ([start]),
      // which reads its screen as well; any other by the hook's word.
      if (!_heldHere(sessionId)) {
        recorder.observe(sessionId, report.status);
      }
      return sessionId;
    } on Object catch (error) {
      _log('a hook could not be read for checkpoints: $error');
      return null;
    }
  }

  /// The row a hook is about: the pane the server runs when it names one and
  /// its own agent fired it (as the daemon's status reads it), else the row
  /// whose conversation it is, else the row its pane was launched as while
  /// that row names no conversation yet. A child agent inheriting its parent
  /// pane's id is not its parent's turn.
  String? _rowOf(String? header, String conversationId) {
    final held = header != null && _heldHere(header);
    if (held && (_ownsConversation?.call(header, conversationId) ?? true)) {
      return header;
    }
    if (conversationId.isNotEmpty) {
      final byConversation = _sessions.getByExternalSessionId(conversationId);
      if (byConversation != null) return byConversation.id;
    }
    if (header == null || held) return null;
    final row = _sessions.getById(header);
    final named = row?.externalSessionId;
    return row != null && (named == null || named.isEmpty) ? row.id : null;
  }

  // Reads, for the agent tools.

  List<Checkpoint> forSession(String sessionId) => _dao.forSession(sessionId);

  List<Checkpoint> recent({int limit = 50}) => _dao.recent(limit: limit);

  Checkpoint? byId(String id) => _dao.getById(id);

  // Checkpoint work, asked by clients.

  /// Answers one [CheckpointWorkRequest] when its git work is done; throws
  /// [DataRefused] in words (an unknown id, a checkout this server cannot
  /// reach).
  Future<Object?> handle(CheckpointWorkRequest<Object?> request) async =>
      switch (request) {
        CheckpointCapture(
          :final sessionId,
          :final label,
          :final decidedBy,
          :final decidedBySessionId,
        ) =>
          recorder.captureNow(
            sessionId,
            label: label,
            decidedBy: decidedBy,
            decidedBySessionId: decidedBySessionId,
          ),
        CheckpointCaptureBase(:final checkout, :final runId, :final label) =>
          captureBase(checkout, runId: runId, label: label),
        CheckpointDiff(:final id) => diffOf(_existing(id)),
        CheckpointRestore(:final id, :final confirm, :final paths) => restore(
          _existing(id),
          confirm: confirm,
          paths: paths,
        ),
        CheckpointSkips() => recorder.skipReasons,
      };

  /// A run's base: [checkout] recorded under [runId] even when unchanged, so
  /// undo has a point to restore to.
  Future<Checkpoint?> captureBase(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  }) {
    _reachable(checkout);
    return service.capture(
      checkout,
      sessionId: runId,
      reason: CheckpointReason.manual,
      label: label,
      evenIfUnchanged: true,
    );
  }

  /// The unified diff [checkpoint] is.
  Future<String> diffOf(Checkpoint checkpoint) {
    _reachable(checkpoint.repository);
    return service.diffOf(checkpoint);
  }

  /// Puts [checkpoint] back — every file, or only [paths] — in its session's
  /// queue, so it never races a turn's capture over the private index. A tree
  /// that moved is answered with the conflict unless [confirm]. Refused while
  /// the session's turn runs, unless that session itself ([requestedBy]) asks.
  Future<CheckpointRestoreAnswer> restore(
    Checkpoint checkpoint, {
    bool confirm = false,
    List<String> paths = const [],
    String? requestedBy,
  }) {
    _reachable(checkpoint.repository);
    final running = turnRunningIn(checkpoint.sessionId, requestedBy);
    if (running != null) {
      throw DataRefused.invalid(
        'A turn of "$running" is running: restoring now would change files '
        'under its agent mid-turn. Nothing was changed. Restore once the turn '
        'has ended, or stop it first.',
      );
    }
    return recorder.queued(checkpoint.sessionId, () async {
      try {
        return CheckpointRestoreAnswer.restored(
          await service.restore(
            checkpoint,
            confirm: confirm,
            selection: [for (final path in paths) HunkSelection(path)],
          ),
        );
      } on CheckpointConflict catch (conflict) {
        return CheckpointRestoreAnswer.refused(conflict);
      } on CheckpointPathsNotFound catch (missing) {
        throw DataRefused.notFound(missing.message);
      }
    });
  }

  /// The title of [sessionId] while its turn runs and someone other than that
  /// session asks to change its files; null when they may.
  String? turnRunningIn(String sessionId, String? requestedBy) {
    if (requestedBy == sessionId || !recorder.inTurn(sessionId)) return null;
    return _sessions.getById(sessionId)?.title ?? sessionId;
  }

  Checkpoint _existing(String id) =>
      _dao.getById(id) ??
      (throw DataRefused.notFound('No checkpoint with id $id.'));

  /// Refuses, in words, a checkout this server cannot run git in.
  void _reachable(EnvironmentPath repository) {
    final reason = service.unsupportedReason(repository);
    if (reason == null) return;
    throw DataRefused.invalid(
      '${reason[0].toUpperCase()}${reason.substring(1)}.',
    );
  }

  // Forks from a checkpoint (`session_fork_from_checkpoint`).

  /// The checkpoints a fork of [sessionId] names — the one [checkpointId]
  /// names, or by [turn] one per repository that turn touched, each taken as
  /// the turn started ([checkpointsAtTurn]) — refused rather than guessed:
  /// `ArgumentError` for naming neither or both, `StateError` for one that is
  /// not there or not that session's, in the tool's words.
  List<Checkpoint> forkCheckpoints({
    required String sessionId,
    String? checkpointId,
    int? turn,
  }) {
    if ((checkpointId == null) == (turn == null)) {
      throw ArgumentError(
        'Name exactly one of checkpointId or turn. checkpoint_list shows both.',
      );
    }
    if (checkpointId != null) {
      final checkpoint = _dao.getById(checkpointId);
      if (checkpoint == null) {
        throw StateError('No checkpoint with id $checkpointId.');
      }
      if (checkpoint.sessionId != sessionId) {
        throw StateError(
          'Checkpoint $checkpointId belongs to session '
          '${checkpoint.sessionId}, not $sessionId.',
        );
      }
      return [checkpoint];
    }
    final chain = _dao.forSession(sessionId);
    final checkpoints = checkpointsAtTurn(chain, turn!);
    if (checkpoints.isEmpty) {
      final available = forkableTurns(chain);
      throw StateError(
        available.isEmpty
            ? 'That session has no checkpoint recorded against a turn, so '
                  'there is no turn to fork from. Name a checkpointId from '
                  'checkpoint_list instead.'
            : 'That session has no checkpoint for turn $turn. It has turns '
                  '${available.join(', ')}.',
      );
    }
    return checkpoints;
  }

  /// The conflict restoring [checkpoint] without confirm would be refused
  /// with, asked in its session's queue and writing no file — so a fork over
  /// several repositories can stop before it changes any of them.
  Future<CheckpointConflict?> forkConflict(Checkpoint checkpoint) {
    _reachable(checkpoint.repository);
    return recorder.queued(
      checkpoint.sessionId,
      () => service.restoreConflict(checkpoint),
    );
  }

  /// What restoring [checkpoint] would change, asked in its session's queue
  /// and writing no file.
  Future<RestorePreview> restorePreview(Checkpoint checkpoint) {
    _reachable(checkpoint.repository);
    return recorder.queued(
      checkpoint.sessionId,
      () => service.restorePreview(checkpoint),
    );
  }

  /// Why the working-tree half of forking [sessionId] from [checkpoint]
  /// cannot be delivered, or null when it can be attempted
  /// ([checkpointForkFileRefusal] over what this server knows: whether it
  /// can reach the checkout, and which other sessions work in it).
  String? forkFileRefusal(
    Checkpoint checkpoint, {
    required String sessionId,
    required bool intoNewWorktree,
    String? requestedBy,
    bool forRewind = false,
  }) => checkpointForkFileRefusal(
    intoNewWorktree: intoNewWorktree,
    forRewind: forRewind,
    turnRunningIn: turnRunningIn(checkpoint.sessionId, requestedBy),
    unsupportedEnvironmentReason: service.unsupportedReason(
      checkpoint.repository,
    ),
    otherSessionsInCheckout: [
      for (final session in sessionsWorkingIn(
        checkpoint.repository,
        excluding: sessionId,
        among: [
          // Only a live agent guards; one with no directory recorded runs in
          // its repository's checkout.
          for (final session in _sessions.getAll())
            if (_live(session))
              if (session.workingDirectory == null && session.worktree == null)
                session.copyWith(
                  workingDirectory: _repositories
                      .getById(session.repositoryId)
                      ?.path,
                )
              else
                session,
        ],
        pathsMatch: samePath,
      ))
        session.title,
    ],
  );

  /// Whether [session]'s agent may be working right now: one this server runs
  /// or sees mid-turn, or a row whose status claims a live agent. An ended
  /// row, or one nothing can see (`unknown`), never guards a checkout.
  bool _live(Session session) =>
      _heldHere(session.id) ||
      recorder.inTurn(session.id) ||
      (!session.isOver && session.status.claimsLive);
}

final class _FunctionClock implements Clock {
  const _FunctionClock(this._now);

  final DateTime Function() _now;

  @override
  DateTime nowUtc() => _now().toUtc();
}
