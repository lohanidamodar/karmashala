import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import '../../notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/evidence.dart';
import 'package:karmashala_notifications/attention.dart';
import '../../terminal/application/pane_exit_signal.dart';
import 'package:agent_cli/stream.dart';
import 'session_engine_provider.dart';
import 'session_launcher.dart';
import 'session_status_providers.dart';

/// **Block until a session settles**, so one agent can hand work to another and
/// know when it is done. Nothing polls; only the caller's bound sets a timer.
class SessionWaitService {
  SessionWaitService(this._ref);

  final Ref _ref;

  /// The bound a caller that names none gets.
  static const Duration defaultBound = Duration(seconds: 30);

  /// The most a caller may ask for. Two 60-second walls sit between a tool call
  /// and its answer — the local RPC timeout, and an MCP client that re-sends.
  static const Duration maxBound = Duration(seconds: 45);

  /// The bound for a caller's `timeoutSeconds`, clamped rather than refused:
  /// `timeout` with the session still running is true whichever bound applied.
  static Duration boundFor(num? seconds) {
    if (seconds == null) return defaultBound;
    final rounded = seconds.round();
    if (rounded <= 0) return defaultBound;
    final asked = Duration(seconds: rounded);
    return asked > maxBound ? maxBound : asked;
  }

  /// **What [sessionId] is blocked on right now**, or null. Asked *before* a
  /// send; only [InboxItemKind.needsApproval] blocks, not a finished item.
  SessionBlock? blockedOn(String sessionId) {
    final report = _ref.read(sessionStatusLookupProvider)(sessionId);
    if (report != null && report.hasOpenQuestion) {
      return SessionBlock(
        kind: 'question',
        text: evidenceLine(report.evidence),
      );
    }
    if (report != null && report.hasOpenPrompt) {
      return SessionBlock(
        kind: 'approvalPrompt',
        text: evidenceLine(report.evidence),
      );
    }
    // At its own input — Claude Code's 60-second "waiting for your input" — the
    // agent is waiting for a message, which is what a send is, not blocked.
    if (report != null && report.waiting == AgentWaitKind.input) return null;
    for (final item in _ref.read(attentionInboxProvider).items) {
      if (item.session.openId != sessionId) continue;
      if (item.kind != InboxItemKind.needsApproval) continue;
      return SessionBlock(kind: item.kind.name, text: item.detail);
    }
    return null;
  }

  /// Blocks until [sessionId] settles, or until [bound] elapses. [inputSent] is
  /// carried through so a timed-out caller knows whether its send went in.
  Future<SessionWaitOutcome> wait(
    String sessionId, {
    Duration? bound,
    bool? inputSent,
  }) async {
    final completer = Completer<SessionWaitOutcome>();
    final launcher = _ref.read(sessionLauncherProvider);
    // Turns taken while waiting: the event log only grows turns through a
    // run the engine holds, so they are counted as it hands them on.
    var turns = 0;
    final taken = _ref
        .read(sessionEngineProvider)
        .watch(sessionId)
        ?.listen((event) {
          if (event.type == SessionEventTypes.userMessage ||
              event.type == SessionEventTypes.agentMessage) {
            turns++;
          }
        });
    AgentStatusReport? opening;
    var changed = false;
    var transcriptMoved = false;

    void settle(SessionWaitOutcome outcome) {
      if (!completer.isCompleted) completer.complete(outcome);
    }

    /// One reading, classified. Null while the session has not settled.
    void consider(AgentStatusReport report) {
      final before = opening;
      if (before == null) {
        opening = report;
      } else {
        // The registry publishes when evidence moved, but *which* matters: a
        // hook ageing out flips `source` with the agent having done nothing.
        if (report.status != before.status ||
            !_sameLines(report.evidence, before.evidence)) {
          changed = true;
        }
        if (_advanced(before.sourceModifiedAt, report.sourceModifiedAt)) {
          changed = true;
          transcriptMoved = true;
        }
      }
      if (turns > 0) {
        changed = true;
        transcriptMoved = true;
      }

      if (launcher.livePaneFor(sessionId) == null) {
        settle(
          _ended(sessionId, report, changed: changed, inputSent: inputSent),
        );
        return;
      }
      if (blockedOn(sessionId) case final block?) {
        settle(
          _outcome(
            SessionWaitState.blocked,
            report,
            changed: changed,
            transcriptMoved: transcriptMoved,
            inputSent: inputSent,
            block: block,
          ),
        );
        return;
      }
      // `awaitingApproval` with no open prompt is an agent at its own input —
      // ready, not blocked. `working` and `unknown` are the two that wait.
      final ready =
          report.status == AgentActivityStatus.idle ||
          report.status == AgentActivityStatus.failed ||
          report.status == AgentActivityStatus.awaitingApproval;
      if (!ready) return;
      settle(
        _outcome(
          changed ? SessionWaitState.done : SessionWaitState.idle,
          report,
          changed: changed,
          transcriptMoved: transcriptMoved,
          inputSent: inputSent,
        ),
      );
    }

    final statuses = _ref
        .read(sessionStatusStreamProvider)(sessionId)
        .listen(consider);
    // Only a process that stopped *by itself* reaches here; closing a pane and
    // `session_end` both drop the listener before disposing.
    final exits = _ref.listen(paneExitProvider, (_, exit) {
      if (exit == null || exit.sessionId != sessionId) return;
      settle(
        _outcome(
          SessionWaitState.ended,
          opening,
          changed: changed,
          transcriptMoved: transcriptMoved,
          inputSent: inputSent,
          exitCode: exit.exitCode,
          // Null is a real answer here, and the one thing it must never become
          // is a zero: a pane whose code we never learned did not succeed.
          exitCodeKnown: exit.exitCode != null,
        ),
      );
    });
    unawaited(
      _ref.read(waitDeadlineProvider)(bound ?? defaultBound).then((_) {
        settle(
          _outcome(
            SessionWaitState.timeout,
            opening,
            changed: changed,
            transcriptMoved: transcriptMoved,
            inputSent: inputSent,
          ),
        );
      }),
    );

    try {
      return await completer.future;
    } finally {
      await statuses.cancel();
      await taken?.cancel();
      exits.close();
    }
  }

  /// The answer for a session with nothing running in it. The exit code is the
  /// last pane exit's, and only when it names this session.
  SessionWaitOutcome _ended(
    String sessionId,
    AgentStatusReport? report, {
    required bool changed,
    required bool? inputSent,
  }) {
    final exit = _ref.read(paneExitProvider);
    final mine = exit != null && exit.sessionId == sessionId;
    return _outcome(
      SessionWaitState.ended,
      report,
      changed: changed,
      transcriptMoved: false,
      inputSent: inputSent,
      exitCode: mine ? exit.exitCode : null,
      exitCodeKnown: mine && exit.exitCode != null,
    );
  }

  SessionWaitOutcome _outcome(
    SessionWaitState state,
    AgentStatusReport? report, {
    required bool changed,
    required bool transcriptMoved,
    required bool? inputSent,
    SessionBlock? block,
    int? exitCode,
    bool exitCodeKnown = false,
  }) {
    final now = _ref.read(clockProvider).nowUtc();
    final since = report?.evidenceAt;
    return SessionWaitOutcome(
      state: state,
      agentStatus: report?.status ?? AgentActivityStatus.unknown,
      source: report?.source ?? AgentStatusSource.none,
      since: since,
      // Computed at the answer rather than stored, because the number a reader
      // needs is how old the evidence is *now*, not when we happened to see it.
      evidenceAge: since == null ? null : now.difference(since),
      changed: changed,
      transcriptChanged: _transcriptChanged(report, transcriptMoved),
      blockedOn: block,
      exitCode: exitCode,
      exitCodeKnown: exitCodeKnown,
      inputSent: inputSent,
    );
  }

  /// Whether the conversation itself moved — `null` when no source could tell,
  /// because `false` would read as "the agent said nothing".
  bool? _transcriptChanged(AgentStatusReport? report, bool moved) {
    if (moved) return true;
    return report?.sourceModifiedAt == null ? null : false;
  }

  static bool _advanced(DateTime? before, DateTime? after) =>
      after != null && (before == null || after.isAfter(before));

  static bool _sameLines(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// What a wait ended on. [done] is idle-and-seen-changed; [idle] is equally
/// true of a session that never started, which is why they are two states.
enum SessionWaitState {
  /// Ready for input, and nothing moved while we watched.
  idle,

  /// Ready for input, and the session's evidence moved during the wait.
  done,

  /// Stopped for a person: an approval prompt, or a question in the inbox.
  blocked,

  /// The pane or the session is over.
  ended,

  /// The caller's bound was reached. The session is still running.
  timeout,
}

/// What a session is blocked on, in the source's own words.
class SessionBlock {
  const SessionBlock({required this.kind, this.text});

  /// `approvalPrompt` for a modal on screen, otherwise the inbox item's kind.
  final String kind;

  /// The agent's own words, or null when the source gave none. Never
  /// synthesised — an absent line reads as "not recorded".
  final String? text;
}

/// One wait's answer.
class SessionWaitOutcome {
  const SessionWaitOutcome({
    required this.state,
    required this.agentStatus,
    required this.source,
    required this.changed,
    this.since,
    this.evidenceAge,
    this.transcriptChanged,
    this.blockedOn,
    this.exitCode,
    this.exitCodeKnown = false,
    this.inputSent,
  });

  final SessionWaitState state;

  /// The status word behind [state], so a turn that ended in `failed` is not
  /// flattened into "done" with the reason dropped.
  final AgentActivityStatus agentStatus;

  final AgentStatusSource source;

  /// When the evidence behind this answer was **produced** — never when we
  /// looked. Null when no source could tell us anything.
  final DateTime? since;

  /// How old that evidence was at the moment of the answer.
  final Duration? evidenceAge;

  /// Whether the session's evidence moved during the wait. The one thing that
  /// separates [SessionWaitState.done] from [SessionWaitState.idle].
  final bool changed;

  /// Whether the conversation moved, or null when no source could tell.
  final bool? transcriptChanged;

  final SessionBlock? blockedOn;

  final int? exitCode;

  /// Whether [exitCode] was learned. A missing code is never a zero.
  final bool exitCodeKnown;

  /// Whether this call sent input before waiting. Null when it sent none.
  final bool? inputSent;
}

/// How a wait's bound is served. Injected so a test can bound a wait by an
/// event it emits rather than by a clock it has to outlast.
typedef WaitDeadline = Future<void> Function(Duration bound);

final waitDeadlineProvider = Provider<WaitDeadline>(
  (ref) =>
      (bound) => Future<void>.delayed(bound),
);

final sessionWaitProvider = Provider<SessionWaitService>(
  SessionWaitService.new,
);
