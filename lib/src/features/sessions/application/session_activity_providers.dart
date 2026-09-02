import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/domain/agent_status.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../domain/session_event_types.dart';
import '../domain/session_launch.dart';
import '../domain/session_status.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_status_providers.dart';

/// **The oldest a tool call may be and still be called "running now".**
///
/// The whole feature rests on one unreliable fact: a `tool_use` with no
/// `tool_result` means *running* and *the transcript stops here* equally. A
/// crashed agent, a killed pane, a remote tail that cut the file short and a
/// turn the user simply abandoned all leave the same shape behind. Without a
/// bound, the strip would eventually announce `Bash · 4h12m` on a session that
/// died before lunch — a confident lie about the user's own machine, which is
/// strictly worse than saying nothing.
///
/// Thirty minutes, chosen against what the two shipped CLIs can actually
/// produce: Claude Code's `Bash` caps its own calls at ten minutes, and the
/// long tail is a `Task` subagent, which in practice finishes well inside half
/// an hour. So the bound sits comfortably above every real call while making an
/// hours-old claim impossible.
///
/// It is deliberately biased toward silence. Exceeding it hides a call that
/// might genuinely still be running; the session's own status badge still says
/// "Working", and an empty strip is a smaller failure than a wrong one.
const Duration kOutstandingCallMaxAge = Duration(minutes: 30);

/// One tool call the agent has issued and not yet answered.
@immutable
class OutstandingCall {
  const OutstandingCall({
    required this.summary,
    required this.toolName,
    required this.startedAt,
  });

  /// The line the transcript already shows — `Bash(git status)`,
  /// `Task(review the diff)`. Taken from [ToolActivity.summary] rather than
  /// re-derived, so the strip and the transcript can never word one call two
  /// ways.
  final String summary;

  /// The tool's own name, kept beside [summary] so a caller can ask what kind
  /// of call this is without parsing the text back apart.
  final String toolName;

  /// When the agent issued the call, from the transcript's own timestamp — see
  /// [TranscriptMessage.at]. Never a first-sighting time: a call whose line
  /// carried no timestamp is dropped instead, because an age we invented is
  /// also an age we cannot age *out*.
  final DateTime startedAt;

  /// Whether this is an in-agent subagent rather than an ordinary tool.
  ///
  /// The one tool that spawns an agent, named by [kSubagentToolName] so this
  /// and the transcript reader agree by construction.
  bool get isSubagent => toolName == kSubagentToolName;

  /// How long it has been outstanding at [now], never negative — a transcript
  /// written by a machine whose clock runs ahead of ours is not evidence of a
  /// call from the future.
  Duration ageAt(DateTime now) {
    final elapsed = now.difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// Whether it is young enough to still be believed — see
  /// [kOutstandingCallMaxAge].
  bool plausibleAt(DateTime now) => ageAt(now) <= kOutstandingCallMaxAge;

  @override
  bool operator ==(Object other) =>
      other is OutstandingCall &&
      other.summary == summary &&
      other.toolName == toolName &&
      other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(summary, toolName, startedAt);

  @override
  String toString() => 'OutstandingCall($summary, $startedAt)';
}

/// What one session has in flight, as of the last transcript it published.
///
/// A value type with real equality on purpose: the transcript is re-parsed on a
/// two-second poll, and a poll that changed nothing must leave the strip
/// asleep rather than handing it a new list of identical calls.
@immutable
class SessionActivity {
  const SessionActivity(this.calls);

  static const none = SessionActivity(<OutstandingCall>[]);

  final List<OutstandingCall> calls;

  /// The calls still young enough to believe at [now].
  ///
  /// Applied here rather than when the list was built, because the transcript
  /// only republishes when the file changes: a session that stops being written
  /// to would otherwise hold its last outstanding call on screen forever. The
  /// strip asks this on every clock tick, so ageing out happens on its own.
  List<OutstandingCall> runningAt(DateTime now) => [
    for (final call in calls)
      if (call.plausibleAt(now)) call,
  ];

  @override
  bool operator ==(Object other) =>
      other is SessionActivity && listEquals(other.calls, calls);

  @override
  int get hashCode => Object.hashAll(calls);
}

/// The `tool_use` blocks in [messages] that no `tool_result` has answered.
///
/// One walk of a list the parse already produced — no second read, no second
/// poll, and nothing here opens a file. Outstanding-ness is read off
/// [TranscriptMessage.pendingToolUseId], which the reader clears when the
/// result lands; `tool.output == null` would have been wrong, because a call
/// that answered with nothing at all looks identical to one still in flight.
///
/// A call whose line carried no timestamp is skipped: without one there is no
/// age, and without an age there is no way to retire it.
List<OutstandingCall> outstandingCallsIn(List<TranscriptMessage> messages) {
  final out = <OutstandingCall>[];
  for (final message in messages) {
    final tool = message.tool;
    final startedAt = message.at;
    if (tool == null || startedAt == null) continue;
    if (message.pendingToolUseId == null) continue;
    out.add(
      OutstandingCall(
        summary: tool.summary,
        toolName: tool.name,
        startedAt: startedAt,
      ),
    );
  }
  return out;
}

/// **What one session is doing right now**, for the strip above its composer.
///
/// Derived entirely from the transcript the conversation is already watching —
/// `sessionChatTranscriptProvider` is an `autoDispose` family, so the view and
/// the strip share one subscription, one poll and one parse. Nothing here adds
/// a read.
///
/// Four gates, and all four have to hold:
///
/// 1. **The session runs in a pane**, so its record is the agent's own
///    transcript. This is not tidiness: the engine's event log emits
///    `tool.call` and never `tool.result` — nothing emits one — so every call
///    in a pre-PTY session's log is unanswered by construction and would read
///    as running forever. It also keeps this from subscribing a native session
///    to a CLI store scan the conversation itself never asks for.
/// 2. **The row is not over.** A session the user stopped is `cancelled` the
///    moment `SessionEngine.stop` returns, which is well before any status
///    source notices. Watched through the `status` concern alone — a title sync
///    runs on the CLI store sweep's own timer and says nothing about this.
/// 3. **The agent is working**, as the app already decides it: the
///    `AgentActivityStatus` the badge, the tray and the notifications all read.
///    `unknown` is not working — an agent we cannot see is one we must not
///    narrate — and neither is `awaitingApproval`, which the approval card
///    above already speaks for.
/// 4. **The call is young enough** — applied by the reader of this value at
///    render time, see [SessionActivity.runningAt].
final sessionOutstandingCallsProvider = Provider.autoDispose
    .family<SessionActivity, String>((ref, sessionId) {
      ref.watchSessionKinds(const {SessionChangeKind.status});
      final row = ref.read(sessionDaoProvider).getById(sessionId);
      if (row == null || row.surface != SessionSurface.pane) {
        return SessionActivity.none;
      }
      if (_isOver(row.status)) return SessionActivity.none;

      final working = ref.watch(
        agentSessionStatusProvider(sessionId).select(
          (report) =>
              report.asData?.value.status == AgentActivityStatus.working,
        ),
      );
      if (!working) return SessionActivity.none;

      final messages =
          ref.watch(sessionChatTranscriptProvider(sessionId)).asData?.value ??
          const <TranscriptMessage>[];
      return SessionActivity(outstandingCallsIn(messages));
    });

/// Whether the row itself says this session has finished, one way or another.
bool _isOver(SessionStatus status) => switch (status) {
  SessionStatus.completed ||
  SessionStatus.failed ||
  SessionStatus.cancelled => true,
  SessionStatus.created || SessionStatus.running || SessionStatus.idle => false,
};
