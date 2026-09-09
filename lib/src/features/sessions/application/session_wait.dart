import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../notifications/domain/evidence_line.dart';
import '../../notifications/domain/inbox_item.dart';
import '../../terminal/application/pane_exit_signal.dart';
import 'package:agent_cli/stream.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';

/// **Block until a session settles**, so one agent can hand work to another and
/// know when it is done.
///
/// ## Why this exists
///
/// `open_new_session`, `session_send` and `session_answer` let an agent start a
/// helper, give it work and answer its prompts. What was missing is the wait:
/// with no way to block, a delegating agent's only option was to re-read the
/// transcript on a loop, which costs a turn per look and still cannot tell
/// "finished something" from "never started".
///
/// ## Nothing polls
///
/// A wait completes on the events the app already emits.
/// [SessionStatusRegistry.reportsFor] publishes when a session's *evidence*
/// moves — a hook callback lands, a transcript is rewritten, a prompt appears —
/// and [paneExitProvider] fires when a pane's process stops by itself. This
/// starts no timer of its own, reads no file and spawns nothing; a session that
/// never changes costs one subscription and nothing else.
///
/// The bound is the one exception, and it is the *caller's* bound rather than a
/// sweep: one delayed future per call, cancelled the moment anything else
/// answers first. See [maxBound] for why it is capped where it is.
class SessionWaitService {
  SessionWaitService(this._ref);

  final Ref _ref;

  /// The bound a caller that names none gets.
  static const Duration defaultBound = Duration(seconds: 30);

  /// The most a caller may ask for, and the number is somebody else's.
  ///
  /// Two independent 60-second walls stand between a tool call and its answer,
  /// and this has to clear both:
  ///
  /// * `kLocalRpcTimeout` — the bridge gives up on a socket that has sent no
  ///   byte for 60 s, which is exactly what a silent wait looks like.
  /// * **The MCP client's own timeout.** Claude Code abandons a call at ~60 s
  ///   *and re-sends it*; `launch_dedupe.dart` exists because that retry
  ///   started a second agent. A retried `session_wait` starts nothing, but it
  ///   still spends the caller's turn on an answer it already has.
  ///
  /// So the cap is well under both, and a caller that wants longer re-calls —
  /// which is honest, because between the two calls it can read the session.
  static const Duration maxBound = Duration(seconds: 45);

  /// The bound for a caller's `timeoutSeconds`, clamped into range.
  ///
  /// A number over the cap is clamped rather than refused: the caller asked for
  /// "as long as you can", and the answer says `timeout` with the session still
  /// running, which is true whichever bound produced it.
  static Duration boundFor(num? seconds) {
    if (seconds == null) return defaultBound;
    final rounded = seconds.round();
    if (rounded <= 0) return defaultBound;
    final asked = Duration(seconds: rounded);
    return asked > maxBound ? maxBound : asked;
  }

  /// **What [sessionId] is blocked on right now**, or null when it is not.
  ///
  /// Synchronous and cheap, because it is asked *before* a send rather than
  /// during a wait: sending into a blocked agent is the failure this answers,
  /// and it has to be answered while there is still time not to send.
  ///
  /// Two sources, in this order. An open approval prompt is positive evidence
  /// that a keystroke would land in a modal — the same
  /// [AgentStatusReport.hasOpenPrompt] gate `session_send` already turns on.
  /// The attention inbox is the wider question: an item there means a person
  /// has been asked for something, whether that is an approval or a question,
  /// and it carries the agent's own words for it.
  ///
  /// Only [InboxItemKind.needsApproval] blocks. A `finished` or `failed` item
  /// is a session waiting to be *read*, which is a session ready for input.
  SessionBlock? blockedOn(String sessionId) {
    final report = _ref.read(sessionStatusLookupProvider)(sessionId);
    if (report != null && report.hasOpenPrompt) {
      return SessionBlock(
        kind: 'approvalPrompt',
        text: evidenceLine(report.evidence),
      );
    }
    for (final item in _ref.read(attentionInboxProvider).items) {
      if (item.session.openId != sessionId) continue;
      if (item.kind != InboxItemKind.needsApproval) continue;
      return SessionBlock(kind: item.kind.name, text: item.detail);
    }
    return null;
  }

  /// Blocks until [sessionId] settles, or until [bound] elapses.
  ///
  /// [inputSent] is what the caller did before waiting, carried through to the
  /// answer untouched. It matters most on a timeout: a caller that retries a
  /// send because the wait ran out submits the work twice, so the answer has to
  /// say whether the first one went in. Null means "this call sent nothing",
  /// which is a third answer and not a `false`.
  Future<SessionWaitOutcome> wait(
    String sessionId, {
    Duration? bound,
    bool? inputSent,
  }) async {
    final completer = Completer<SessionWaitOutcome>();
    final launcher = _ref.read(sessionLauncherProvider);
    final baselineTurns = _turns(sessionId);
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
        // The registry publishes only when evidence moved, but *which* evidence
        // matters: a hook ageing out flips `source` without the agent having
        // done anything. Status, the agent's own words and the transcript's
        // mtime are the three that mean work happened.
        if (report.status != before.status ||
            !_sameLines(report.evidence, before.evidence)) {
          changed = true;
        }
        if (_advanced(before.sourceModifiedAt, report.sourceModifiedAt)) {
          changed = true;
          transcriptMoved = true;
        }
      }
      if (_turns(sessionId) > baselineTurns) {
        changed = true;
        transcriptMoved = true;
      }

      if (launcher.livePaneFor(sessionId) == null) {
        settle(_ended(sessionId, report, changed: changed, inputSent: inputSent));
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
      // `awaitingApproval` with no open prompt is an agent sitting at its own
      // input — Claude Code's post-turn nudge — which is ready for input, not
      // blocked. `failed` ends the turn too, and the status word rides along so
      // the caller can see it ended badly. `working` and `unknown` are the two
      // that keep waiting: an unknown is never reported as settled.
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

    final statuses = _ref.read(sessionStatusStreamProvider)(sessionId).listen(
      consider,
    );
    // Only a process that stopped *by itself* reaches here — closing a pane and
    // `session_end` both drop the listener before disposing — so this is the
    // prompt path for the ordinary ending, and the `livePaneFor` check above is
    // what covers the rest.
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
      exits.close();
    }
  }

  /// The answer for a session with nothing running in it.
  ///
  /// The exit code comes from the last pane exit, and only when it names this
  /// session: any other exit is another pane's business, and attributing it
  /// here would be inventing a code.
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

  /// Whether the conversation itself moved — `null` when no source could tell.
  ///
  /// A hook callback carries no transcript position and a PTY session keeps no
  /// event log, so for the most ordinary session in this app the honest answer
  /// is "not recorded". Reporting that as `false` would be the confident false
  /// statement §19 exists to delete: it reads as "the agent said nothing".
  bool? _transcriptChanged(AgentStatusReport? report, bool moved) {
    if (moved) return true;
    return report?.sourceModifiedAt == null ? null : false;
  }

  int _turns(String sessionId) => _ref
      .read(sessionEventDaoProvider)
      .listForSession(sessionId)
      .where(
        (event) =>
            event.type == SessionEventTypes.userMessage ||
            event.type == SessionEventTypes.agentMessage,
      )
      .length;

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

/// What a wait ended on.
///
/// [idle] and [done] both mean *ready for input*, and they are two states
/// rather than one because a caller that delegated work cannot act on them the
/// same way: [done] is idle-and-seen-changed, so it says the session finished
/// something, while [idle] says only that it is not busy — which is equally
/// true of a session that never started.
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

/// How a wait's bound is served.
///
/// Injected so a test can bound a wait by an event it emits rather than by a
/// clock it has to outlast: a suite that proved a timeout by sleeping would
/// spend real seconds to observe something that is not about time at all.
typedef WaitDeadline = Future<void> Function(Duration bound);

final waitDeadlineProvider = Provider<WaitDeadline>(
  (ref) => (bound) => Future<void>.delayed(bound),
);

final sessionWaitProvider = Provider<SessionWaitService>(
  SessionWaitService.new,
);
