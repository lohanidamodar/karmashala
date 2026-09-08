import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../domain/session.dart';
import '../domain/session_event_types.dart';
import '../domain/session_launch.dart';
import '../domain/session_status.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_status_providers.dart';

/// Why an empty activity answer must not be read as "nothing is running".
///
/// A fact, never a sentence: the wire carries which nothing it is and each end
/// words it — the same split [RemoteTranscriptAbsence] is built to.
enum ActivityBlindSpot {
  /// The session is working and nothing here records *what on*.
  ///
  /// Two shapes, one meaning. Either there is no transcript we can read — no
  /// external id yet, an agent whose store this app cannot open — or the record
  /// we do have is the engine's event log, which emits `tool.call` and never
  /// `tool.result` and so cannot tell a finished call from a running one.
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

  /// The line the transcript already shows — `Bash(git status)`,
  /// `Agent(review the diff)`. Taken from [ToolActivity.summary] rather than
  /// re-derived, so the strip and the transcript can never word one call two
  /// ways. For a shell call that line **is** the command: `command` is the
  /// first of [kToolSubjectKeys], so nothing extra has to be carried to name
  /// what a `Bash` call is running.
  final String summary;

  /// The tool's own name, kept beside [summary] so a caller can ask what kind
  /// of call this is without parsing the text back apart.
  final String toolName;

  /// When the agent issued the call, from the transcript's own timestamp — see
  /// [TranscriptMessage.at]. Never a first-sighting time: a call whose line
  /// carried no timestamp is dropped instead, because an age we invented would
  /// be an age we were inventing a claim about.
  final DateTime startedAt;

  /// Whether this is an in-agent subagent rather than an ordinary tool.
  ///
  /// The tools that spawn an agent, named by [kSubagentToolNames] so this and
  /// the transcript reader agree by construction.
  bool get isSubagent => isSubagentToolName(toolName);

  /// How long it has been outstanding at [now], never negative — a transcript
  /// written by a machine whose clock runs ahead of ours is not evidence of a
  /// call from the future.
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
///
/// Three shapes, and they are three different sentences:
///
/// * [calls] is not empty — these are running.
/// * [calls] is empty and [blindSpot] is null — **nothing is running**, and we
///   could see that.
/// * [blindSpot] is set — **we cannot tell**, and it says why.
///
/// A value type with real equality on purpose: the transcript is re-parsed on a
/// two-second poll, and a poll that changed nothing must leave the strip asleep
/// rather than handing it a new list of identical calls.
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

/// **The calls in [messages] that are still running**, of both kinds.
///
/// One walk of a list the parse already produced — no second read, no second
/// poll, and nothing here opens a file. A call whose line carried no timestamp
/// is skipped either way: without one there is no age to show beside it.
///
/// ### Two kinds, because the CLI runs them two ways
///
/// **A foreground call** is outstanding: a `tool_use` no `tool_result` has
/// answered, read off [TranscriptMessage.pendingToolUseId]. (`tool.output ==
/// null` would have been wrong — a call that answered with nothing at all
/// looks identical to one still in flight.)
///
/// **A background subagent** is never outstanding for more than a moment:
/// Claude Code answers the parent's `Agent` call at once with
/// `async_launched` and reports the outcome much later. The two runs on
/// 2026-09-07 took 76 and 80 minutes, so no rule about a call's age could have
/// found either. [TranscriptMessage.pendingBackgroundAgentId] is what sees
/// them.
///
/// **Neither is marked as which**, here or in the strip. Whether the CLI held
/// the parent's tool call open or answered it with a stub is a fact about the
/// CLI — that detail already changed once, when `Task` became `Agent` — and
/// not about the user's work. The distinction a reader needs is subagent
/// versus tool, which [OutstandingCall.isSubagent] carries.
///
/// Oldest first, and by one walk: a background launch is recorded on the row
/// of the call that started it, so the two kinds interleave in transcript
/// order rather than concatenating.
///
/// **This session's own calls, at depth 1.** A delegate that spawns a delegate
/// records that launch in *its* transcript, not the parent's — the owner's
/// largest session has 109 such refs on disk, at depths 2 and 3, and none of
/// their launches appears here. Reading them would mean opening the 519 MiB of
/// delegate transcripts this whole design refuses to open on a poll, so a
/// nested agent is left unclaimed rather than counted or denied.
List<OutstandingCall> outstandingCallsIn(List<TranscriptMessage> messages) {
  final out = <OutstandingCall>[];
  for (final message in messages) {
    final tool = message.tool;
    final startedAt = message.at;
    if (tool == null || startedAt == null) continue;
    // Mutually exclusive by construction: the reader clears
    // `pendingToolUseId` in the same step that records the async launch, so a
    // background subagent can never be counted twice.
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
/// word one session two ways.
///
/// [messages] is null for "we have no record to read"; [status] is null for a
/// session no status source has answered for yet.
///
/// ### What retires a call
///
/// **Whether the session is still observably working** — never how long the
/// call has been out. This used to be a thirty-minute ceiling on the call's own
/// age, chosen against what the shipped CLIs were believed to produce, and the
/// belief was wrong on the owner's own machine: the longest unanswered tool
/// window in that store is a `Bash` call at **514.8 minutes**, and two subagent
/// runs on 2026-09-07 reported 76 and 80 minutes. A ceiling above every real
/// call cannot be chosen, because the age of a call is not evidence about
/// whether it is running.
///
/// The reading that *is* evidence already exists and is already taken every
/// 1.2 s (`kStatusCycleInterval`): the `AgentActivityStatus` the badge, the
/// tray and the notifications all read. A session that died stops being
/// `working` on its own, and quickly — a hook report is refused once it is
/// older than `AgentStatusService.hookFreshness`, and a `working` state-file
/// record whose file has stopped moving becomes `unknown` after
/// `AgentStateFileRules.activityWindow`. So the backstop the ceiling was
/// standing in for is structural, in the sources themselves, and bounded by
/// their own constants rather than by a guess here. Nothing in this file needs
/// a clock, and §19's "one reading, not two" is why it must not take a second
/// opinion on a question the status pipeline has already answered.
///
/// ### What retires a *background* subagent
///
/// The same answer, and no clock here either. A launch the CLI never reported
/// on means "running" or "it died with the session" — the ambiguity above —
/// but it needs one thing the outstanding rule did not: the CLI's own
/// reconciliation. 95 of the 311 background subagents in the owner's largest
/// session never got a notification at all, so "launched and unreported" alone
/// would have drawn 95 running agents on a session that had four. What prunes
/// them is in [TranscriptMessage.pendingBackgroundAgentId].
///
/// It leaves the ledger honest but not clairvoyant, and the split is the
/// designed one. Run over all 72 transcripts in the owner's store on
/// 2026-09-08: 64 hold nothing, the one live session holds exactly the agents
/// that were really running, and 7 dead sessions hold 1 to 3 entries each — an
/// agent that died with its CLI and got no notification and no boundary after
/// it. Every one of those 7 is silenced here, by gate 2, because a dead
/// session is not working. That is the same division of labour the outstanding
/// rule already relies on, and it is why neither needs a clock.
///
/// **The phone learns about it for free.** `session.activity` already carries a
/// call as summary, tool name, `subagent` and `startedAt` against the host's
/// own `observedAt`, and the host builds that list from [SessionActivity.calls]
/// — so a background subagent rides the frame `Capability.viewActivity`
/// already gates, with no new bit and no new field.
///
/// ### The gates, in order
///
/// 1. **The row is not over.** A session the user stopped is `cancelled` the
///    moment `SessionEngine.stop` returns, which is well before any status
///    source notices.
/// 2. **The agent is working**, as the app already decides it. `unknown` is not
///    working — an agent we cannot see is one we must not narrate — and neither
///    is `awaitingApproval`, which the approval card above already speaks for.
///    Both leave [SessionActivity.none] rather than a blind spot: the status
///    badge one row up already says which of them it is.
/// 3. **There is a record that can answer.** From here the session *is*
///    working, so an empty list would be a claim — and when we have nothing to
///    base it on the answer is [ActivityBlindSpot.noRecord] instead.
SessionActivity sessionActivityFrom({
  required SessionStatus rowStatus,
  required SessionSurface surface,
  required AgentActivityStatus? status,
  required List<TranscriptMessage>? messages,
}) {
  if (_isOver(rowStatus)) return SessionActivity.none;
  if (status != AgentActivityStatus.working) return SessionActivity.none;
  // A session outside our panes renders from the engine's event log, which has
  // no result event to clear a call with — so it cannot answer this question at
  // all, rather than answering it with nothing.
  if (surface != SessionSurface.pane || messages == null) {
    return const SessionActivity.blind(ActivityBlindSpot.noRecord);
  }
  return SessionActivity(outstandingCallsIn(messages));
}

/// **What one session is doing right now**, for the strip above its composer.
///
/// Derived entirely from the transcript the conversation is already watching —
/// `sessionChatTranscriptProvider` is an `autoDispose` family, so the view and
/// the strip share one subscription, one poll and one parse. Nothing here adds
/// a read, and nothing here polls.
///
/// The rule is [sessionActivityFrom]; this only gathers its inputs. The status
/// is selected down to the one word the rule turns on, so a cycle that
/// reconfirms what a session was already doing rebuilds nothing — and the
/// transcript is subscribed **only** once that word is `working`, which keeps a
/// quiet session from paying for a CLI store scan the conversation never asked
/// for.
final sessionOutstandingCallsProvider = Provider.autoDispose
    .family<SessionActivity, String>((ref, sessionId) {
      ref.watchSessionKinds(const {SessionChangeKind.status});
      final row = ref.read(sessionDaoProvider).getById(sessionId);
      if (row == null) return SessionActivity.none;

      // The one word the rule turns on, and nothing else: `AgentStatusReport`
      // has no value equality, so selecting the report itself would rebuild on
      // every 1.2-second cycle that reconfirmed what a session was doing.
      final status = ref.watch(
        agentSessionStatusProvider(sessionId).select((r) => r.asData?.value.status),
      );
      final working =
          !_isOver(row.status) && status == AgentActivityStatus.working;
      // Null rather than empty for a record we are not reading: the rule tells
      // "nothing outstanding" from "nothing to look at" by exactly this, and
      // the chat source cannot — it answers a session it cannot read with an
      // empty list and never an error, on purpose.
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

/// Whether there is a record of this session's turns we could read at all.
///
/// The same three facts `sessionHasChatView` asks of the view and
/// `_agentRecordMessages` asks for the wire, so all three agree: a CLI session
/// id we have been told, an installation that still exists, and an agent whose
/// store this app can open (`agentSupportsChatView` — Antigravity's is protobuf
/// in an unpublished schema). Answered from DAOs the provider has already
/// opened; nothing here touches the disk.
bool hasReadableRecord(Ref ref, Session session) {
  final externalId = session.externalSessionId;
  if (externalId == null || externalId.isEmpty) return false;
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  if (agentId == null) return false;
  return agentSupportsChatView(ref.read(agentRegistryProvider).byId(agentId));
}

/// Whether the row itself says this session has finished, one way or another.
///
/// [SessionStatus.unknown] is not finished: it is the row saying we lost sight
/// of the session, and losing sight of one is not an ending — the working gate
/// decides it anyway, and that gate cannot hold for a session nothing can see.
bool _isOver(SessionStatus status) => switch (status) {
  SessionStatus.completed ||
  SessionStatus.failed ||
  SessionStatus.cancelled => true,
  SessionStatus.created ||
  SessionStatus.running ||
  SessionStatus.idle ||
  SessionStatus.unknown => false,
};
