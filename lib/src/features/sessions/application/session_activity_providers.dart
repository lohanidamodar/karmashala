import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../domain/session.dart';
import 'package:agent_cli/stream.dart';
import '../domain/session_launch.dart';
import '../domain/session_status.dart';
import 'session_chat_source.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_status_providers.dart';

/// Why an empty activity answer must not be read as "nothing is running". A
/// fact, never a sentence: the wire carries which nothing it is, and each end
/// words it.
enum ActivityBlindSpot {
  /// The session is working and nothing here records *what on* — either no
  /// transcript we can read, or the engine's event log, which emits `tool.call`
  /// and never `tool.result` and so cannot tell a finished call from a live
  /// one.
  noRecord,
}

/// One tool call the agent has issued and not yet answered.
@immutable
class OutstandingCall {
  const OutstandingCall({
    required this.summary,
    required this.toolName,
    required this.startedAt,
  });

  /// The line the transcript already shows — `Bash(git status)`. Taken from
  /// [ToolActivity.summary] rather than re-derived, so the strip and the
  /// transcript can never word one call two ways.
  final String summary;

  /// The tool's own name, kept beside [summary] so a caller can ask what kind
  /// of call this is without parsing the text back apart.
  final String toolName;

  /// When the agent issued the call, from the transcript's own timestamp. Never
  /// a first-sighting time: a line that carried none is dropped instead,
  /// because an age we invented would be a claim we invented.
  final DateTime startedAt;

  /// Whether this is an in-agent subagent rather than an ordinary tool, named
  /// by [kSubagentToolNames] so this and the transcript reader agree by
  /// construction.
  bool get isSubagent => isSubagentToolName(toolName);

  /// How long it has been outstanding at [now], never negative — a transcript
  /// from a clock that runs ahead of ours is not a call from the future.
  Duration ageAt(DateTime now) {
    final elapsed = now.difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

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
/// Non-empty [calls] means these are running; empty with no [blindSpot] means
/// nothing is running and we could see that; a [blindSpot] means we cannot
/// tell. Real equality on purpose: the transcript is re-parsed on a two-second
/// poll, and a poll that changed nothing must leave the strip asleep.
@immutable
class SessionActivity {
  const SessionActivity(this.calls) : blindSpot = null;

  /// We cannot say what this session is doing, and [spot] is why.
  const SessionActivity.blind(ActivityBlindSpot spot)
    : calls = const <OutstandingCall>[],
      blindSpot = spot;

  /// Nothing is running — an answer, not an absence of one.
  static const none = SessionActivity(<OutstandingCall>[]);

  final List<OutstandingCall> calls;

  /// Why [calls] is empty, when it is empty for a reason worth saying. Null
  /// means the answer stands on its own.
  final ActivityBlindSpot? blindSpot;

  @override
  bool operator ==(Object other) =>
      other is SessionActivity &&
      other.blindSpot == blindSpot &&
      listEquals(other.calls, calls);

  @override
  int get hashCode => Object.hash(blindSpot, Object.hashAll(calls));

  @override
  String toString() => blindSpot == null
      ? 'SessionActivity(${calls.length} running)'
      : 'SessionActivity(blind: ${blindSpot!.name})';
}

/// **The calls in [messages] that are still running**, of both kinds — one walk
/// of a list the parse already produced; nothing here opens a file, and a line
/// with no timestamp is skipped because there would be no age to show beside
/// it.
///
/// A foreground call is a `tool_use` no `tool_result` has answered
/// (`tool.output == null` would read a call that answered with nothing as still
/// in flight); a background subagent is answered at once with `async_launched`
/// and reported much later, so no rule about a call's age could find one.
/// Neither is marked as which: that is a fact about the CLI, not about the
/// user's work.
///
/// Only this session's own calls, at depth 1 — a delegate that spawns a
/// delegate records the launch in *its* transcript, and reading those means
/// opening the delegate transcripts this design refuses to open on a poll, so a
/// nested agent is left unclaimed rather than counted or denied.
List<OutstandingCall> outstandingCallsIn(List<TranscriptMessage> messages) {
  final out = <OutstandingCall>[];
  for (final message in messages) {
    final tool = message.tool;
    final startedAt = message.at;
    if (tool == null || startedAt == null) continue;
    // Mutually exclusive by construction: the reader clears `pendingToolUseId`
    // in the same step that records the async launch.
    if (message.pendingToolUseId == null &&
        message.pendingBackgroundAgentId == null) {
      continue;
    }
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

/// **The one rule that decides what a session is doing right now**, shared by
/// the desktop strip and by what the companion is told, so the two can never
/// word one session two ways. [messages] is null for "we have no record to
/// read"; [status] is null for a session no status source has answered for yet.
///
/// A call is retired by whether the session is still observably working, never
/// by its age: the longest real unanswered tool window in the owner's store is
/// a `Bash` call at 514.8 minutes, so no ceiling above every real call exists.
/// The evidence is `AgentActivityStatus`, already read every 1.2 s and already
/// expiring on its sources' own constants — nothing here needs a clock. A
/// background subagent retires the same way plus the CLI's own reconciliation,
/// in [TranscriptMessage.pendingBackgroundAgentId]: most launches are never
/// reported at all, so "launched and unreported" alone would draw agents that
/// died with their session.
///
/// The gates, in order: the row is not over (a session the user stopped is
/// `cancelled` before any status source notices); the agent is working, as the
/// app already decides it (`unknown` and `awaitingApproval` both give
/// [SessionActivity.none] — the badge one row up says which); and there is a
/// record that can answer, or the answer is [ActivityBlindSpot.noRecord] rather
/// than an empty list that would be a claim.
SessionActivity sessionActivityFrom({
  required SessionStatus rowStatus,
  required SessionSurface surface,
  required AgentActivityStatus? status,
  required List<TranscriptMessage>? messages,
}) {
  if (_isOver(rowStatus)) return SessionActivity.none;
  if (status != AgentActivityStatus.working) return SessionActivity.none;
  // A session outside our panes renders from the engine's event log, which has
  // no result event to clear a call with, so it cannot answer this at all.
  if (surface != SessionSurface.pane || messages == null) {
    return const SessionActivity.blind(ActivityBlindSpot.noRecord);
  }
  return SessionActivity(outstandingCallsIn(messages));
}

/// **What one session is doing right now**, for the strip above its composer.
/// Derived entirely from the transcript the conversation is already watching,
/// so the view and the strip share one subscription, one poll and one parse.
/// The rule is [sessionActivityFrom]; the transcript is subscribed **only**
/// once the status word is `working`, which keeps a quiet session from paying
/// for a CLI store scan the conversation never asked for.
final sessionOutstandingCallsProvider = Provider.autoDispose
    .family<SessionActivity, String>((ref, sessionId) {
      ref.watchSessionKinds(const {SessionChangeKind.status});
      final row = ref.read(sessionDaoProvider).getById(sessionId);
      if (row == null) return SessionActivity.none;

      // The one word the rule turns on: `AgentStatusReport` has no value
      // equality, so selecting the report itself would rebuild every 1.2 s.
      final status = ref.watch(
        agentSessionStatusProvider(sessionId).select((r) => r.asData?.value.status),
      );
      final working =
          !_isOver(row.status) && status == AgentActivityStatus.working;
      // Null rather than empty for a record we are not reading: the rule tells
      // "nothing outstanding" from "nothing to look at" by exactly this, and
      // the chat source cannot — it answers an unreadable session with an empty
      // list.
      final messages =
          working &&
              row.surface == SessionSurface.pane &&
              hasReadableRecord(ref, row)
          ? ref.watch(sessionChatTranscriptProvider(sessionId)).asData?.value
          : null;
      return sessionActivityFrom(
        rowStatus: row.status,
        surface: row.surface,
        status: status,
        messages: messages,
      );
    });

/// Whether there is a record of this session's turns we could read at all — the
/// same reading the conversation and the companion snapshot use, so none of the
/// three can say "this agent keeps no transcript" about a session whose
/// transcript is on disk. Watched, not read: the reading starts at a prior and
/// settles once the probe answers, and this gate has to move with it.
bool hasReadableRecord(Ref ref, Session session) =>
    ref.watch(sessionChatViewProvider(session.id)).hasChatView;

/// Whether the row itself says this session has finished, one way or another.
/// [SessionStatus.unknown] is not finished: it is the row saying we lost sight
/// of the session, and losing sight of one is not an ending.
bool _isOver(SessionStatus status) => switch (status) {
  SessionStatus.completed ||
  SessionStatus.failed ||
  SessionStatus.cancelled => true,
  SessionStatus.created ||
  SessionStatus.running ||
  SessionStatus.idle ||
  SessionStatus.unknown => false,
};
