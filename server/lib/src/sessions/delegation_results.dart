import 'dart:async';

import 'package:karmashala_session/session.dart' show QueuedMessageState;
import 'package:karmashala_session_engine/store.dart'
    show
        SessionDelegation,
        SessionDelegationDao,
        kReportModeEachTurn,
        kReportModeFinal,
        kReportModeNone;

import '../status/child_turn_wait.dart';
import 'session_queue.dart';
import 'session_subagents.dart' show boundedText;

/// The most of one child's answer a pushed result carries; the rest is read
/// with `session_transcript`.
const int kDelegationAnswerMaxChars = 4000;

/// How long an async child's first turn is watched before its parent is told
/// it is still running.
const Duration kDelegationBound = Duration(hours: 6);

/// How a delegation's last report came: the child's own, or a turn's end.
const String kReportViaChild = 'report';
const String kReportViaTurn = 'turn';

/// A child a session started, and what its parent asked to be told of it.
class DelegatedChild {
  const DelegatedChild({
    required this.childId,
    required this.parentId,
    required this.title,
    required this.agent,
    required this.startedAt,
    this.model,
    this.endOnAnswer = false,
    this.reportMode = kReportModeEachTurn,
  });

  /// `none`, `final` or `each_turn` (`kReportModes`).
  final String reportMode;

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

/// What a child says of itself with `report_to_parent`.
enum ReportStatus {
  done('done', 'done'),
  blocked('blocked', 'BLOCKED'),
  needsInput('needs_input', 'needs input');

  const ReportStatus(this.wire, this.words);

  /// As the tool takes it and the store keeps it.
  final String wire;
  final String words;

  static ReportStatus? byWire(String wire) {
    for (final status in values) {
      if (status.wire == wire) return status;
    }
    return null;
  }
}

/// What became of a child's own report.
enum ReportDelivery {
  /// Put in its parent's queue.
  delivered,

  /// Its parent has ended, was archived or deleted, or nothing runs it: kept
  /// on the child's delegation, never queued.
  parentGone,

  /// Its parent asked to be told nothing: kept on the child's delegation.
  notWanted,
}

/// A child's own report to the session that started it.
class ParentReport {
  const ParentReport({
    required this.childId,
    required this.parentId,
    required this.title,
    required this.agent,
    required this.status,
    required this.text,
  });

  final String childId;
  final String parentId;
  final String title;

  /// The agent's display name.
  final String agent;
  final ReportStatus status;
  final String text;
}

/// Where a child stands for its parent, read now.
class DelegationView {
  const DelegationView({
    required this.state,
    required this.followed,
    this.reportState,
    this.reportVia,
    this.reportedAt,
    this.reportMode,
    this.reportText,
    this.reportDelivered,
  });

  /// `running`, `idle`, `reported done`, `blocked`, `needs input`, `failed`
  /// or `ended`.
  final String state;

  /// What the parent asked to hear; null for a child never recorded.
  final String? reportMode;

  /// The last report's text, and whether it reached the parent: one kept
  /// for a parent that was gone reads false.
  final String? reportText;
  final bool? reportDelivered;

  /// Whether its turn ends are pushed to its parent.
  final bool followed;
  final String? reportState;

  /// [kReportViaChild] or [kReportViaTurn].
  final String? reportVia;
  final DateTime? reportedAt;
}

/// One awaited turn of a delegated child: which, and from when its answer
/// counts. A [next] follow waits for whatever turn the child works next; its
/// [turn] is decided when that turn settles.
final class _Follow {
  _Follow(this.child, this.turn, this.since, {this.next = false});

  final DelegatedChild child;
  final int turn;
  final DateTime since;
  final bool next;
}

/// **A delegated child's result, pushed to its parent** — the async mode of
/// `subagent_run` and `open_new_session`. When a turn of a watched child
/// settles — its first, and every one it works after, for its parent or
/// anyone — its result goes into the parent's [SessionQueue]: delivered at
/// once to an idle parent, after the running turn to a busy one. A child
/// sitting idle pushes nothing. Results that land within [batchWindow] of
/// each other, or while an earlier batch still waits in the queue, go as one
/// message. Each delegation is kept in [store], so [start] re-arms what a
/// restart left awaited.
class DelegationResults {
  DelegationResults({
    required this.turnOf,
    required this.nextTurnOf,
    required this.answerOf,
    required this.queue,
    required this.store,
    required this.isLive,
    bool Function(String parentId)? parentReachable,
    this.isWorking,
    this.isArchived,
    this.restoreGrace = const Duration(minutes: 2),
    this.endChild,
    this.batchWindow = const Duration(seconds: 2),
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc()),
       parentReachable = parentReachable ?? isLive;

  /// Whether a report may be queued for [String]: it exists, is neither
  /// ended nor archived, and something runs it. Never true of a parent a
  /// report would have to resume.
  final bool Function(String parentId) parentReachable;

  /// Settles when [String]'s first turn since [DateTime] does —
  /// `ChildTurnWait.firstTurn` under [kDelegationBound].
  final Future<ChildTurnOutcome> Function(String childId, DateTime since)
  turnOf;

  /// Settles when the next turn [String] works does — `ChildTurnWait.nextTurn`.
  final Future<ChildTurnOutcome> Function(String childId, DateTime since)
  nextTurnOf;

  /// Whether row [String]'s turn is running now (`TurnSettlement.running`).
  final bool Function(String sessionId)? isWorking;

  /// Whether row [String] is archived: its delegation then ends unreported.
  final bool Function(String sessionId)? isArchived;
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

  /// Re-arms every turn a parent still awaited when the server last stopped,
  /// and follows again every other child that comes back running.
  void start() {
    for (final row in store.open()) {
      final child = _childOf(row);
      if (row.turnStartedAt case final since?) {
        final follow = _watched[child.childId] = _Follow(
          child,
          row.turn,
          since,
        );
        unawaited(_restore(follow));
      } else {
        unawaited(_standWhenLive(child));
      }
    }
  }

  static DelegatedChild _childOf(SessionDelegation row) => DelegatedChild(
    childId: row.childSessionId,
    parentId: row.parentSessionId,
    title: row.title,
    agent: row.agent,
    model: row.model,
    startedAt: row.delegatedAt,
    endOnAnswer: row.endOnAnswer,
    reportMode: row.reportMode,
  );

  /// Records [child] and, unless its parent asked for nothing, watches its
  /// first turn.
  void watch(DelegatedChild child) {
    final silent = child.reportMode == kReportModeNone;
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
        turnStartedAt: silent ? null : child.startedAt,
        reportMode: child.reportMode,
        closedAt: silent ? child.startedAt : null,
      ),
    );
    if (silent) return;
    final follow = _watched[child.childId] = _Follow(child, 1, child.startedAt);
    unawaited(_follow(follow));
  }

  /// [parentId] changes what it is told of [child] to `child.reportMode`:
  /// `none` stops following it, anything else follows the turn it works
  /// next. False when [child] is not [parentId]'s.
  bool setMode(DelegatedChild child, String parentId) {
    final id = child.childId;
    final row = store.byChild(id);
    if (row == null) {
      if (child.parentId != parentId) return false;
      watch(child);
      return true;
    }
    if (row.parentSessionId != parentId) return false;
    store.setReportMode(id, child.reportMode, at: _now());
    // A follow already running reads the new mode when its turn settles.
    if (child.reportMode == kReportModeNone) {
      _watched.remove(id);
    } else if (!_watched.containsKey(id) && isLive(id)) {
      _stand(_childOf(store.byChild(id)!));
    }
    log?.call('delegation $id: reports ${child.reportMode}');
    return true;
  }

  /// [callerSessionId] sent [sessionId] a message (`session_send`): from its
  /// parent, to a delegation nothing follows now — one that ended between
  /// turns and was resumed by the send — it arms that turn's push.
  void sent(String? callerSessionId, String sessionId, [DateTime? at]) {
    if (callerSessionId == null) return;
    final row = store.byChild(sessionId);
    if (row == null || row.parentSessionId != callerSessionId) return;
    if (_watched.containsKey(sessionId)) return;
    final since = at ?? _now();
    final armed = store.awaitNextTurn(sessionId, since: since);
    if (armed == null) return;
    final follow = _watched[sessionId] = _Follow(
      _childOf(armed),
      armed.turn,
      since,
    );
    log?.call('delegation $sessionId: turn ${armed.turn} is awaited');
    unawaited(_follow(follow));
  }

  /// Follows the next turn [child] works, whenever that is.
  void _stand(DelegatedChild child) {
    final follow = _watched[child.childId] = _Follow(
      child,
      0,
      _now(),
      next: true,
    );
    unawaited(_follow(follow));
  }

  /// [_stand] for a child a restart left between turns, once it runs again.
  Future<void> _standWhenLive(DelegatedChild child) async {
    final waited = Stopwatch()..start();
    while (!_closed &&
        !isLive(child.childId) &&
        waited.elapsed < restoreGrace) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_closed || !isLive(child.childId)) return;
    if (_watched.containsKey(child.childId)) return;
    if (store.byChild(child.childId)?.isOpen != true) return;
    _stand(child);
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
    final had = _watched.remove(childId) != null;
    if (store.byChild(childId)?.isOpen != true && !had) return;
    store.close(childId, at: _now());
    log?.call('delegation $childId: stopped; nothing more is pushed');
  }

  /// A child's own [report], put in its parent's queue at once — never
  /// batched, never lifting a pause — and kept as its last. The turn it was
  /// made in is not pushed as well. A child nothing follows is recorded as a
  /// closed delegation, so its parent's list still shows it.
  ReportDelivery report(ParentReport report) {
    final at = _now();
    final row = store.byChild(report.childId);
    final delivery = row?.reportMode == kReportModeNone
        ? ReportDelivery.notWanted
        : parentReachable(report.parentId)
        ? ReportDelivery.delivered
        : ReportDelivery.parentGone;
    final text = boundedText(report.text.trim(), kDelegationAnswerMaxChars).$1;
    if (delivery == ReportDelivery.delivered) {
      queue.postDelegation(
        report.parentId,
        parentReportMessage(report),
        originId: report.childId,
      );
    }
    final recorded = store.reported(
      report.childId,
      state: report.status.wire,
      via: kReportViaChild,
      at: at,
      text: text,
      delivered: delivery == ReportDelivery.delivered,
    );
    if (!recorded) {
      store.put(
        SessionDelegation(
          childSessionId: report.childId,
          parentSessionId: report.parentId,
          title: report.title,
          agent: report.agent,
          delegatedAt: at,
          turn: 0,
          reportState: report.status.wire,
          reportVia: kReportViaChild,
          reportedAt: at,
          closedAt: at,
          reportText: text,
          reportDelivered: delivery == ReportDelivery.delivered,
        ),
      );
    }
    log?.call(
      'delegation ${report.childId}: reported ${report.status.wire} to '
      '${report.parentId}: ${delivery.name}',
    );
    return delivery;
  }

  /// Where [childId] stands for its parent: ended when nothing runs it,
  /// running while it works or before its first turn settles, else its last
  /// report, or idle when it has none.
  DelegationView viewOf(String childId) {
    final row = store.byChild(childId);
    final String state;
    if (!isLive(childId)) {
      state = 'ended';
    } else if ((isWorking?.call(childId) ?? false) ||
        (row != null && row.awaiting && row.reportVia != kReportViaChild)) {
      state = 'running';
    } else {
      state = switch (row?.reportState) {
        null => 'idle',
        'done' => 'reported done',
        'needs_input' => 'needs input',
        final other => other,
      };
    }
    return DelegationView(
      state: state,
      followed: row?.isOpen ?? false,
      reportState: row?.reportState,
      reportVia: row?.reportVia,
      reportedAt: row?.reportedAt,
      reportMode: row?.reportMode,
      reportText: row?.reportText,
      reportDelivered: row?.reportDelivered,
    );
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
    final id = child.childId;
    ChildTurnOutcome outcome;
    try {
      outcome = await (follow.next
          ? nextTurnOf(id, follow.since)
          : turnOf(id, follow.since));
    } on Object catch (error) {
      log?.call('delegation $id: the wait failed: $error');
      outcome = ChildTurnOutcome(ChildTurnState.ended, idle: follow.next);
    }
    if (_closed || !identical(_watched[id], follow)) return;
    if (isArchived?.call(id) ?? false) {
      _watched.remove(id);
      store.close(id, at: _now());
      log?.call('delegation $id: archived; nothing more is pushed');
      return;
    }
    final mode = store.byChild(id)?.reportMode ?? child.reportMode;
    if (outcome.idle) {
      _watched.remove(id);
      final row = store.byChild(id);
      // Under `final` the child ending is its last word, unless it gave one.
      if (mode == kReportModeFinal &&
          row != null &&
          row.isOpen &&
          row.reportVia != kReportViaChild) {
        final last = _Follow(child, row.turn, child.startedAt);
        _report(
          last,
          ChildTurnOutcome(
            ChildTurnState.ended,
            exitCode: outcome.exitCode,
            exitCodeKnown: outcome.exitCodeKnown,
          ),
          await _answer(last),
        );
        return;
      }
      log?.call('delegation $id: ended between turns; followed again when '
          'its parent sends to it');
      return;
    }
    var settled = follow;
    if (follow.next) {
      final row = store.awaitNextTurn(id, since: follow.since);
      if (row == null) {
        _watched.remove(id);
        return;
      }
      settled = _Follow(child, row.turn, follow.since);
    }
    final over =
        outcome.state == ChildTurnState.ended ||
        (child.endOnAnswer && outcome.state == ChildTurnState.done);
    // Followed again before the answer is read, so a turn that starts at
    // once — a queued follow-up delivered as this one ended — is not missed.
    if (over) {
      _watched.remove(id);
    } else {
      _stand(child);
    }
    // The child said what it had to with report_to_parent during this turn.
    final row = store.byChild(id);
    if (row != null &&
        row.reportVia == kReportViaChild &&
        (row.reportedAt?.isAfter(follow.since) ?? false)) {
      final ended = child.endOnAnswer && outcome.state == ChildTurnState.done
          ? await _end(id)
          : null;
      if (over || ended == true) {
        store.close(id, at: _now());
      } else {
        store.turnReported(id, turn: settled.turn);
      }
      log?.call('delegation $id: turn ${settled.turn} reported by the child');
      return;
    }
    // `final` hears of a turn only when the child cannot go on or is done
    // for good; a turn that merely finished waits for its own report.
    final wanted =
        mode != kReportModeFinal ||
        over ||
        outcome.state == ChildTurnState.blocked ||
        outcome.state == ChildTurnState.failed;
    if (!wanted) {
      store.turnReported(id, turn: settled.turn);
      return;
    }
    final answer = switch (outcome.state) {
      ChildTurnState.running || ChildTurnState.blocked => null,
      _ => await _answer(settled),
    };
    // Stopped while the answer was read.
    if (_closed || store.byChild(id)?.isOpen != true) return;
    final ended = child.endOnAnswer && outcome.state == ChildTurnState.done
        ? await _end(id)
        : null;
    _report(settled, outcome, answer, ended: ended);
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
    // A parent that is gone is never queued anything, nor resumed by it:
    // each result stays on its child's delegation instead.
    final reachable = parentReachable(parentId);
    if (reachable) {
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
    } else {
      _batches.remove(parentId);
      log?.call(
        'delegation: $parentId is gone; ${fresh.length} result(s) kept on '
        'the children',
      );
    }
    // Reported only once it is in the queue, so a restart before then
    // reports it again rather than never.
    for (final (result, follow) in fresh) {
      final childId = follow.child.childId;
      store.reported(
        childId,
        state: result.outcome.state.name,
        via: kReportViaTurn,
        at: _now(),
        text: switch (result.answer) {
          final answer? => boundedText(answer, kDelegationAnswerMaxChars).$1,
          null => null,
        },
        delivered: reachable,
      );
      final over =
          result.outcome.state == ChildTurnState.ended || result.ended == true;
      if (over) {
        store.close(childId, at: _now());
        continue;
      }
      store.turnReported(childId, turn: follow.turn);
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

/// The message a parent is given for a child's own [report].
String parentReportMessage(ParentReport report) {
  final id = report.childId;
  final (text, cut) = boundedText(report.text.trim(), kDelegationAnswerMaxChars);
  final out = StringBuffer()
    ..writeln(
      '[Karmashala] "${report.title}" (session $id · ${report.agent}), a '
      'session you started, reports: ${report.status.words}.',
    )
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
  out
    ..writeln()
    ..write(switch (report.status) {
      ReportStatus.done =>
        'Follow up with session_send, or end it with session_end when you '
            'are done with it.',
      ReportStatus.blocked =>
        'It cannot go on by itself: answer it with session_send, or ask the '
            'user.',
      ReportStatus.needsInput =>
        'It is waiting for your answer: reply with session_send '
            '(sessionId: $id).',
    });
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
      'Still working; the end of its turn is pushed when it comes.',
  };
}

/// [took] as "2m 5s", "45s" or "1h 3m".
String formatTook(Duration took) {
  final s = took.inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
}
