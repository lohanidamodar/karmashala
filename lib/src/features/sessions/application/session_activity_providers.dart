import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/launch.dart';
import 'session_chat_source.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_status_providers.dart';

/// Why an empty activity answer must not be read as "nothing is running" — a
/// fact, never a sentence, because each end words it for itself.
enum ActivityBlindSpot {
  /// The session is working and nothing here records *what on*: no readable
  /// transcript, or a log that emits `tool.call` and never `tool.result`.
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

  /// The line the transcript already shows, from [ToolActivity.summary] rather
  /// than re-derived, so strip and transcript cannot word one call two ways.
  final String summary;

  /// The tool's own name, kept beside [summary] so a caller can ask what kind
  /// of call this is without parsing the text back apart.
  final String toolName;

  /// When the agent issued the call, from the transcript's own timestamp — a
  /// line that carried none is dropped rather than given an invented age.
  final DateTime startedAt;

  /// Whether this is an in-agent subagent, named by [kSubagentToolNames] so
  /// this and the transcript reader agree by construction.
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

/// What one session has in flight. A [blindSpot] means we cannot tell, which is
/// not an empty list; real equality keeps a two-second re-parse from waking it.
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

/// **The calls in [messages] still running**, of both kinds, in one walk of a
/// list the parse already produced. This session's own calls only, at depth 1.
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

/// **The one rule for what a session is doing right now.** A call is retired by
/// whether the session is still observably working, never by its own age.
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

/// **What one session is doing right now**, from the transcript the
/// conversation watches — subscribed only while the status word is `working`.
final sessionOutstandingCallsProvider = Provider.autoDispose
    .family<SessionActivity, String>((ref, sessionId) {
      ref.watchSessionKinds(const {SessionChangeKind.status});
      final row = ref.read(sessionDaoProvider).getById(sessionId);
      if (row == null) return SessionActivity.none;

      // The one word the rule turns on: `AgentStatusReport` has no value
      // equality, so selecting the report itself would rebuild every 1.2 s.
      final status = ref.watch(
        agentSessionStatusProvider(
          sessionId,
        ).select((r) => r.asData?.value.status),
      );
      final working =
          !_isOver(row.status) && status == AgentActivityStatus.working;
      // Null rather than empty for a record we are not reading: this is how
      // the rule tells "nothing outstanding" from "nothing to look at".
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
/// same reading the conversation uses. Watched, not read: a prior can settle.
bool hasReadableRecord(Ref ref, Session session) =>
    ref.watch(sessionChatViewProvider(session.id)).hasChatView;

/// Whether the row itself says this session has finished. `unknown` is not:
/// losing sight of a session is not an ending.
bool _isOver(SessionStatus status) => switch (status) {
  SessionStatus.completed ||
  SessionStatus.failed ||
  SessionStatus.cancelled => true,
  SessionStatus.created ||
  SessionStatus.running ||
  SessionStatus.idle ||
  SessionStatus.unknown => false,
};
