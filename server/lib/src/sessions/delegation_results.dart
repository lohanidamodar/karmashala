import 'dart:async';

import 'package:karmashala_session/session.dart' show QueuedMessageState;
import 'package:karmashala_session_engine/store.dart'
    show SessionDelegation, SessionDelegationDao;

import '../status/child_turn_wait.dart';
import 'session_queue.dart';
import 'session_subagents.dart' show boundedText;

/// The most of one child's answer a pushed result carries; the rest is read
/// with `session_transcript`.
const int kDelegationAnswerMaxChars = 4000;

/// How long an async child is watched before its parent is told it is still
/// running and no more is pushed.
const Duration kDelegationBound = Duration(hours: 6);

/// A child started in async mode, whose first turn's result is pushed to its
/// parent.
class DelegatedChild {
  const DelegatedChild({
    required this.childId,
    required this.parentId,
    required this.title,
    required this.agent,
    required this.startedAt,
    this.model,
    this.endOnAnswer = false,
  });

  final String childId;
  final String parentId;
  final String title;

  /// The agent's display name.
  final String agent;

  /// Null when the child runs its agent's default model.
  final String? model;
  final DateTime startedAt;

  /// End the child once it answers (`subagent_run` without `keepOpen`).
  final bool endOnAnswer;
}

/// One child's result, as it reached its parent.
class DelegationResult {
  const DelegationResult({
    required this.child,
    required this.outcome,
    required this.answer,
    required this.took,
    this.ended,
    this.turn = 1,
  });

  final DelegatedChild child;
  final ChildTurnOutcome outcome;

  /// What the child said last since the turn began; null when nothing.
  final String? answer;
  final Duration took;

  /// Whether the child was ended once it answered; null when not asked to.
  final bool? ended;

  /// Which of the child's turns this is: 1, or a follow-up's.
  final int turn;
}

/// One awaited turn of a delegated child: which, and from when its answer
/// counts.
final class _Follow {
  _Follow(this.child, this.turn, this.since);

  final DelegatedChild child;
  final int turn;
  final DateTime since;
}

/// **A delegated child's result, pushed to its parent** — the async mode of
/// `subagent_run` and `open_new_session`. When a watched child's turn settles
/// — its first, or one its parent asked for with a follow-up ([sent]) — its
/// result goes into the parent's [SessionQueue]: delivered at once to an idle
/// parent, after the running turn to a busy one. Results that land within
/// [batchWindow] of each other, or while an earlier batch still waits in the
/// queue, go as one message. Each delegation is kept in [store], so [start]
/// re-arms what a restart left awaited.
class DelegationResults {
  DelegationResults({
    required this.turnOf,
    required this.answerOf,
    required this.queue,
    required this.store,
    required this.isLive,
    this.restoreGrace = const Duration(minutes: 2),
    this.endChild,
    this.batchWindow = const Duration(seconds: 2),
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  /// Settles when [String]'s first turn since [DateTime] does —
  /// `ChildTurnWait.firstTurn` under [kDelegationBound].
  final Future<ChildTurnOutcome> Function(String childId, DateTime since)
  turnOf;
  final AnswerOf answerOf;
  final SessionQueue queue;
  final SessionDelegationDao store;

  /// Whether something runs row [String] now.
  final bool Function(String sessionId) isLive;

  /// How long [start] waits for a restored child nothing runs yet — a turn
  /// the restart cut off is continued a moment later — before reading it as
  /// ended.
  final Duration restoreGrace;
  final Future<void> Function(String childId)? endChild;
  final Duration batchWindow;
  final void Function(String message)? log;
  final DateTime Function() _now;

  final _watched = <String, _Follow>{};

  /// Children whose parent sent a follow-up while a turn was awaited: the
  /// next turn is awaited once that one is reported.
  final _followUps = <String>{};
  final _pending = <String, List<(DelegationResult, _Follow)>>{};
  final _timers = <String, Timer>{};

  /// Per parent: the queued row its batch is in, and every result in it.
  final _batches = <String, ({String rowId, List<DelegationResult> results})>{};
  var _closed = false;

  /// The children of [parentId] still watched, oldest first.
  List<DelegatedChild> watching(String parentId) => [
    for (final follow in _watched.values)
      if (follow.child.parentId == parentId) follow.child,
  ];

  /// Re-arms every turn a parent still awaited when the server last stopped.
  void start() {
    for (final row in store.awaiting()) {
      final since = row.turnStartedAt!;
      final child = DelegatedChild(
        childId: row.childSessionId,
        parentId: row.parentSessionId,
        title: row.title,
        agent: row.agent,
        model: row.model,
        startedAt: row.delegatedAt,
        endOnAnswer: row.endOnAnswer,
      );
      final follow = _watched[child.childId] = _Follow(child, row.turn, since);
      unawaited(_restore(follow));
    }
  }

  /// Starts watching [child]'s first turn; its result is pushed when it
  /// settles.
  void watch(DelegatedChild child) {
    store.put(
      SessionDelegation(
        childSessionId: child.childId,
        parentSessionId: child.parentId,
        title: child.title,
        agent: child.agent,
        model: child.model,
        endOnAnswer: child.endOnAnswer,
        delegatedAt: child.startedAt,
        turn: 1,
        turnStartedAt: child.startedAt,
      ),
    );
    final follow = _watched[child.childId] = _Follow(child, 1, child.startedAt);
    unawaited(_follow(follow));
  }

  /// [callerSessionId] sent [sessionId] a message (`session_send`): from its
  /// parent, to a delegation, it arms that turn's push.
  void sent(String? callerSessionId, String sessionId, [DateTime? at]) {
    if (callerSessionId == null) return;
    final row = store.byChild(sessionId);
    if (row == null || row.parentSessionId != callerSessionId) return;
    if (row.awaiting) {
      // It lands behind the turn awaited now; the next is awaited after.
      _followUps.add(sessionId);
      return;
    }
    _arm(sessionId, at ?? _now());
  }

  void _arm(String childId, DateTime since) {
    final row = store.awaitNextTurn(childId, since: since);
    if (row == null) return;
    final follow = _watched[childId] = _Follow(
      DelegatedChild(
        childId: row.childSessionId,
        parentId: row.parentSessionId,
        title: row.title,
        agent: row.agent,
        model: row.model,
        startedAt: row.delegatedAt,
        endOnAnswer: row.endOnAnswer,
      ),
      row.turn,
      since,
    );
    log?.call('delegation $childId: turn ${row.turn} is awaited');
    unawaited(_follow(follow));
  }

  /// [callerSessionId] ended [sessionId] (`session_end`): its parent doing
  /// so is the parent stopping the delegation.
  void endedBy(String? callerSessionId, String sessionId) {
    if (callerSessionId == null) return;
    if (store.byChild(sessionId)?.parentSessionId != callerSessionId) return;
    stopped(sessionId);
  }

  /// [childId] was stopped by a person, or ended by its parent: what it says
  /// next is not pushed.
  void stopped(String childId) {
    _followUps.remove(childId);
    final had = _watched.remove(childId) != null;
    if (store.byChild(childId) == null && !had) return;
    store.remove(childId);
    log?.call('delegation $childId: stopped; nothing more is pushed');
  }

  Future<void> close() async {
    _closed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  /// A restored turn: one already answered while nothing ran it is reported
  /// at once; one nothing runs yet gets [restoreGrace] to come back.
  Future<void> _restore(_Follow follow) async {
    final childId = follow.child.childId;
    if (!isLive(childId)) {
      if (await _answer(follow) case final answer?) {
        if (_closed || !identical(_watched.remove(childId), follow)) return;
        _report(
          follow,
          const ChildTurnOutcome(ChildTurnState.done),
          answer,
          ended: follow.child.endOnAnswer ? true : null,
        );
        return;
      }
      final waited = Stopwatch()..start();
      while (!_closed && !isLive(childId) && waited.elapsed < restoreGrace) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    await _follow(follow);
  }

  Future<void> _follow(_Follow follow) async {
    final child = follow.child;
    ChildTurnOutcome outcome;
    try {
      outcome = await turnOf(child.childId, follow.since);
    } on Object catch (error) {
      log?.call('delegation ${child.childId}: the wait failed: $error');
      outcome = const ChildTurnOutcome(ChildTurnState.ended);
    }
    if (_closed || !identical(_watched[child.childId], follow)) return;
    final answer = switch (outcome.state) {
      ChildTurnState.running || ChildTurnState.blocked => null,
      _ => await _answer(follow),
    };
    if (_closed || !identical(_watched.remove(child.childId), follow)) return;
    final ended = child.endOnAnswer && outcome.state == ChildTurnState.done
        ? await _end(child.childId)
        : null;
    _report(follow, outcome, answer, ended: ended);
  }

  void _report(
    _Follow follow,
    ChildTurnOutcome outcome,
    String? answer, {
    bool? ended,
  }) {
    final child = follow.child;
    final result = DelegationResult(
      child: child,
      outcome: outcome,
      answer: answer,
      took: _now().difference(follow.since),
      ended: ended,
      turn: follow.turn,
    );
    (_pending[child.parentId] ??= []).add((result, follow));
    _timers[child.parentId] ??= Timer(
      batchWindow,
      () => _flush(child.parentId),
    );
  }

  Future<String?> _answer(_Follow follow) async {
    try {
      return (await answerOf(follow.child.childId, since: follow.since))?.text;
    } on Object {
      return null;
    }
  }

  Future<bool?> _end(String childId) async {
    final end = endChild;
    if (end == null) return null;
    try {
      await end(childId);
      return true;
    } on Object catch (error) {
      log?.call('delegation $childId: could not end it: $error');
      return false;
    }
  }

  void _flush(String parentId) {
    _timers.remove(parentId);
    final fresh = _pending.remove(parentId);
    if (_closed || fresh == null || fresh.isEmpty) return;
    // A batch still waiting in the queue grows; one on its way is closed.
    final batch = _batches[parentId];
    final growing =
        batch != null &&
        queue.dao.getById(batch.rowId)?.state == QueuedMessageState.queued;
    final results = [
      if (growing) ...batch.results,
      for (final (r, _) in fresh) r,
    ];
    final row = queue.postDelegation(
      parentId,
      delegationMessage(results),
      replacing: growing ? batch.rowId : null,
      originId: fresh.last.$1.child.childId,
    );
    _batches[parentId] = (rowId: row.id, results: results);
    log?.call(
      'delegation: ${fresh.length} result(s) for $parentId in ${row.id}',
    );
    // Reported only once it is in the queue, so a restart before then
    // reports it again rather than never.
    for (final (result, follow) in fresh) {
      final childId = follow.child.childId;
      final over =
          result.outcome.state == ChildTurnState.ended || result.ended == true;
      if (over) {
        _followUps.remove(childId);
        store.remove(childId);
        continue;
      }
      store.turnReported(childId, turn: follow.turn);
      if (_followUps.remove(childId)) _arm(childId, _now());
    }
  }
}

/// The message a parent is given for [results]: who reported, on which agent
/// and model, how long it took, and its answer, bounded.
String delegationMessage(List<DelegationResult> results) {
  final out = StringBuffer(
    results.length == 1
        ? '[Karmashala] A session you delegated has reported back.'
        : '[Karmashala] ${results.length} sessions you delegated have '
              'reported back.',
  );
  for (final result in results) {
    final child = result.child;
    final id = child.childId;
    out
      ..writeln()
      ..writeln()
      ..writeln(
        '## "${child.title}" — ${_stateWords(result)}'
        '${result.turn > 1 ? ' (turn ${result.turn}, a follow-up)' : ''}',
      )
      ..writeln(
        'Session $id · ${child.agent} · '
        'model ${child.model ?? "the agent's default"} · '
        'took ${formatTook(result.took)}',
      );
    final answer = result.answer;
    if (answer != null) {
      final (text, cut) = boundedText(answer, kDelegationAnswerMaxChars);
      out
        ..writeln()
        ..writeln(text);
      if (cut) {
        out
          ..writeln()
          ..writeln(
            '[cut at $kDelegationAnswerMaxChars characters; the rest is in '
            'session_transcript (sessionId: $id)]',
          );
      }
    }
    out
      ..writeln()
      ..write(_next(result));
  }
  return out.toString();
}

String _stateWords(DelegationResult result) => switch (result.outcome.state) {
  ChildTurnState.done => 'done',
  ChildTurnState.failed => 'failed',
  ChildTurnState.blocked => 'BLOCKED on a person',
  ChildTurnState.ended => 'its process ended',
  ChildTurnState.running => 'still running',
};

String _next(DelegationResult result) {
  final id = result.child.childId;
  final block = result.outcome.block;
  final said = block?.text?.trim() ?? '';
  final asked = said.isEmpty ? '' : ': "$said"';
  final transcript = 'Full transcript: session_transcript (sessionId: $id).';
  return switch (result.outcome.state) {
    ChildTurnState.done => switch (result.ended) {
      true => '$transcript It was ended once it answered.',
      false =>
        '$transcript Ending it failed; end it with session_end when done.',
      null => '$transcript It is still open for a follow-up with session_send.',
    },
    ChildTurnState.failed =>
      '$transcript It stopped on a failure and is still open.',
    ChildTurnState.blocked =>
      'It stopped for ${block?.kind ?? 'an approval or a question'}$asked. '
          'Ask the user, or answer an approval with session_answer, then '
          'session_wait on $id.',
    ChildTurnState.ended =>
      '$transcript Exit code '
          '${result.outcome.exitCodeKnown ? '${result.outcome.exitCode}' : 'unknown'}.',
    ChildTurnState.running =>
      'Not pushed again: session_wait on $id for its answer.',
  };
}

/// [took] as "2m 5s", "45s" or "1h 3m".
String formatTook(Duration took) {
  final s = took.inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
}
