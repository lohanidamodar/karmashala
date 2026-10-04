import 'dart:async';

import 'package:karmashala_session/session.dart' show QueuedMessageState;

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
  });

  final DelegatedChild child;
  final ChildTurnOutcome outcome;

  /// What the child said last since it started; null when nothing.
  final String? answer;
  final Duration took;

  /// Whether the child was ended once it answered; null when not asked to.
  final bool? ended;
}

/// **A delegated child's result, pushed to its parent** — the async mode of
/// `subagent_run` and `open_new_session`. When a watched child's first turn
/// settles, its result goes into the parent's [SessionQueue]: delivered at
/// once to an idle parent, after the running turn to a busy one. Results that
/// land within [batchWindow] of each other, or while an earlier batch still
/// waits in the queue, go as one message.
class DelegationResults {
  DelegationResults({
    required this.turnOf,
    required this.answerOf,
    required this.queue,
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
  final Future<void> Function(String childId)? endChild;
  final Duration batchWindow;
  final void Function(String message)? log;
  final DateTime Function() _now;

  final _watched = <String, DelegatedChild>{};
  final _pending = <String, List<DelegationResult>>{};
  final _timers = <String, Timer>{};

  /// Per parent: the queued row its batch is in, and every result in it.
  final _batches = <String, ({String rowId, List<DelegationResult> results})>{};
  var _closed = false;

  /// The children of [parentId] still watched, oldest first.
  List<DelegatedChild> watching(String parentId) => [
    for (final child in _watched.values)
      if (child.parentId == parentId) child,
  ];

  /// Starts watching [child]; its result is pushed when its turn settles.
  void watch(DelegatedChild child) {
    _watched[child.childId] = child;
    unawaited(_follow(child));
  }

  /// A person stopped [childId]: what it says next is theirs, not its
  /// parent's, so nothing is pushed for it.
  void stopped(String childId) {
    if (_watched.remove(childId) != null) {
      log?.call('delegation $childId: stopped by a person; nothing is pushed');
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _follow(DelegatedChild child) async {
    ChildTurnOutcome outcome;
    try {
      outcome = await turnOf(child.childId, child.startedAt);
    } on Object catch (error) {
      log?.call('delegation ${child.childId}: the wait failed: $error');
      outcome = const ChildTurnOutcome(ChildTurnState.ended);
    }
    if (_closed || !identical(_watched[child.childId], child)) return;
    final answer = switch (outcome.state) {
      ChildTurnState.running || ChildTurnState.blocked => null,
      _ => await _answer(child),
    };
    if (_closed || !identical(_watched.remove(child.childId), child)) return;
    final ended =
        child.endOnAnswer && outcome.state == ChildTurnState.done
        ? await _end(child.childId)
        : null;
    final result = DelegationResult(
      child: child,
      outcome: outcome,
      answer: answer,
      took: _now().difference(child.startedAt),
      ended: ended,
    );
    (_pending[child.parentId] ??= []).add(result);
    _timers[child.parentId] ??= Timer(
      batchWindow,
      () => _flush(child.parentId),
    );
  }

  Future<String?> _answer(DelegatedChild child) async {
    try {
      return (await answerOf(child.childId, since: child.startedAt))?.text;
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
    final results = [if (growing) ...batch.results, ...fresh];
    final row = queue.postDelegation(
      parentId,
      delegationMessage(results),
      replacing: growing ? batch.rowId : null,
      originId: fresh.last.child.childId,
    );
    _batches[parentId] = (rowId: row.id, results: results);
    log?.call(
      'delegation: ${fresh.length} result(s) for $parentId in ${row.id}',
    );
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
      ..writeln('## "${child.title}" — ${_stateWords(result)}')
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
      null =>
        '$transcript It is still open for a follow-up with session_send.',
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
