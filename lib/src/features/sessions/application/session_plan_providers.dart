import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_plan.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../domain/session_launch.dart';
import 'session_chat_source.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **How long a plan can stand still before it is worth pointing at.**
///
/// Fifteen minutes, taken from agenttrail (`0d5d151`), which infers a missed
/// `Stop` after exactly that and archives a run after two hours — the same
/// problem from the other end. Borrowed rather than invented because the number
/// has been lived with, and because `Stop` is precisely the event we cannot
/// rely on for every agent here.
///
/// **It is not a claim that the agent is stuck**, and nothing worded from it
/// may say so. It says the plan has not moved in fifteen minutes, which is a
/// reading with an age on it (§19) rather than a diagnosis. An agent can sit on
/// one item for an hour legitimately; the point is that a reader should be able
/// to see which of four is the one that has.
const Duration kPlanGoesStaleAfter = Duration(minutes: 15);

/// Why there is no plan to draw. Four shapes, because they are four different
/// sentences and collapsing them is what makes an empty list a lie.
enum AgentPlanAbsence {
  /// **This agent keeps no plan we can read.** A capability answer, measured
  /// per CLI and carried on the descriptor with its evidence — see
  /// [AgentPlanSupport]. The panel says so in words rather than drawing an
  /// empty list, which reads as "no work planned".
  agentPublishesNone,

  /// The agent does keep one, and has not written one in this conversation
  /// yet. An answer, not an absence of one.
  noneYet,

  /// There is no record of this session's turns we could read at all — no CLI
  /// session id yet, an installation that is gone, a session running somewhere
  /// that is not one of our panes.
  noRecord,

  /// **There is a record and we have not read it.** The transcript is re-read
  /// only while a conversation is the surface in front (see
  /// [chatTranscriptPollingProvider]); nothing here arms a second poll to close
  /// that, so this is the honest answer while every group shows its terminal.
  notRead,
}

/// **One reading of an agent's own plan, with the age of the reading on it.**
///
/// §19's rule, applied to the one surface where a stale value is worse than no
/// value: a plan that has been overtaken looks exactly like a plan that is
/// current, and a reader glancing at four of them cannot tell which is which
/// without the age.
///
/// [writtenAt] is **when the agent wrote the plan**, from the transcript line's
/// own timestamp — never a first-sighting time, the same rule
/// [OutstandingCall.startedAt] follows. One age rather than two (written, read)
/// on purpose: a plan we hold can never be newer than the last time we read the
/// file, so the written time is already the conservative of the pair, and a
/// second number nobody can act on is a number that trains the eye to skip the
/// row.
///
/// A value type with real equality, for [SessionActivity]'s reason: the file
/// moves constantly and a re-parse that found the same plan must leave the
/// panel asleep.
class AgentPlanReading {
  const AgentPlanReading.of(AgentPlan this.plan, {required this.writtenAt})
    : absence = null,
      refusal = '';

  /// There is nothing to draw, and [absence] says which nothing it is.
  /// [refusal] is the sentence behind it when there is a more specific one —
  /// the agent's own recorded refusal for [AgentPlanAbsence.agentPublishesNone],
  /// and `SessionChatView.reason` for [AgentPlanAbsence.noRecord].
  const AgentPlanReading.absent(AgentPlanAbsence this.absence,
      {this.refusal = ''})
    : plan = null,
      writtenAt = null;

  final AgentPlan? plan;

  /// When the agent wrote this plan, or null when its line carried no
  /// timestamp — which is the only honest answer, and the reason nothing
  /// downstream may assume an age exists.
  final DateTime? writtenAt;

  final AgentPlanAbsence? absence;

  final String refusal;

  bool get hasPlan => plan != null;

  /// How old the plan is at [now], never negative — a transcript written by a
  /// machine whose clock runs ahead of ours is not evidence of a plan from the
  /// future. Null when the line carried no timestamp.
  Duration? ageAt(DateTime now) {
    final at = writtenAt;
    if (at == null) return null;
    final elapsed = now.difference(at);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// Whether this plan has work left in it and has not moved for
  /// [kPlanGoesStaleAfter].
  ///
  /// False for a finished plan however old it is: a list whose items are all
  /// done is a completed piece of work, not a stalled one, and marking it would
  /// be the loudest wrong answer this panel could give.
  bool isStaleAt(DateTime now) {
    final current = plan;
    if (current == null || current.isFinished) return false;
    final age = ageAt(now);
    return age != null && age >= kPlanGoesStaleAfter;
  }

  @override
  bool operator ==(Object other) =>
      other is AgentPlanReading &&
      other.plan == plan &&
      other.writtenAt == writtenAt &&
      other.absence == absence &&
      other.refusal == refusal;

  @override
  int get hashCode => Object.hash(plan, writtenAt, absence, refusal);

  @override
  String toString() => plan == null
      ? 'AgentPlanReading(absent: ${absence?.name})'
      : 'AgentPlanReading($plan @ $writtenAt)';
}

/// **The plan [messages] leaves standing: the last snapshot, and when it was
/// written.**
///
/// One walk of a list the parse already produced — no second read, no second
/// poll, and nothing here opens a file, exactly as [outstandingCallsIn] does.
///
/// **Last one wins, and that is measured rather than assumed.** Both CLIs that
/// have a plan resend the whole list on every change (the counts are on
/// [kClaudeCodeTodoWrite] and [kCodexUpdatePlan]), so folding would draw items
/// the agent had already dropped — one real session goes 15 items → 4 → 11 and
/// ends at 1. A CLI that publishes deltas would need a different fold, which is
/// why [AgentPlanStyle] records which kind each one is instead of leaving it
/// implicit here.
///
/// A row whose plan failed to parse contributes **nothing** rather than an
/// empty plan, so a format that changed under us leaves the last plan we did
/// understand on screen with its age, rather than replacing it with "no work
/// planned".
AgentPlanReading agentPlanIn(List<TranscriptMessage> messages) {
  AgentPlan? plan;
  DateTime? at;
  for (final message in messages) {
    final published = message.tool?.plan;
    if (published == null) continue;
    plan = published;
    at = message.at;
  }
  return plan == null
      ? const AgentPlanReading.absent(AgentPlanAbsence.noneYet)
      : AgentPlanReading.of(plan, writtenAt: at);
}

/// **The plan one session's agent is working to**, for the panel beside its
/// pane.
///
/// Derived entirely from the transcript the conversation is already watching —
/// `sessionChatTranscriptProvider` is an `autoDispose` family, so the panel, the
/// conversation and the activity strip share one subscription, one poll and one
/// parse. Nothing here adds a read, and **nothing here polls**.
///
/// The consequence is stated rather than hidden: that subscription only works
/// while a conversation is the surface in front, so with every group showing
/// its terminal this answers [AgentPlanAbsence.notRead] and then, once it has
/// read, an ageing plan that says how old it is. Closing that gap would mean
/// either a second poll — refused — or a hook path, and neither was built here.
///
/// Not gated on the session *working*, unlike
/// [sessionOutstandingCallsProvider]: a finished plan on an idle agent is worth
/// exactly as much as a live one, and telling those two apart is the question
/// the panel exists for.
final sessionAgentPlanProvider = Provider.autoDispose
    .family<AgentPlanReading, String>((ref, sessionId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
      });
      final row = ref.read(sessionDaoProvider).getById(sessionId);
      if (row == null) {
        return const AgentPlanReading.absent(AgentPlanAbsence.noRecord);
      }

      // The capability answer comes first and costs nothing: an agent that
      // keeps no plan must never reach a transcript subscription — nor a
      // `SessionChatView` probe — to find that out. Antigravity is the one that
      // publishes none, and whether its *record* can be read is now a separate
      // per-session question this never has to ask.
      final agentId = ref
          .read(agentInstallationDaoProvider)
          .getById(row.agentInstallationId)
          ?.agentId;
      final support =
          (agentId == null
              ? null
              : ref.read(agentRegistryProvider).byId(agentId)?.plan) ??
          const AgentPlanSupport.none();
      if (!support.isSupported) {
        return AgentPlanReading.absent(
          AgentPlanAbsence.agentPublishesNone,
          refusal: support.refusal,
        );
      }

      if (row.surface != SessionSurface.pane) {
        return const AgentPlanReading.absent(
          AgentPlanAbsence.noRecord,
          refusal:
              'This session runs in a terminal we do not own, so there is no '
              'transcript of it here to read.',
        );
      }

      // **Which nothing, in the reading's own words.** The panel used to say
      // "it is running somewhere this app cannot follow, or it has not said
      // anything yet" for every shape at once; `SessionChatView.reason` tells
      // an unreadable store from a session whose transcript file is simply not
      // there, and this is the sentence the panel draws.
      final chatView = ref.watch(sessionChatViewProvider(sessionId));
      if (!chatView.hasChatView) {
        return AgentPlanReading.absent(
          AgentPlanAbsence.noRecord,
          refusal: chatView.reason,
        );
      }

      final messages = ref
          .watch(sessionChatTranscriptProvider(sessionId))
          .asData
          ?.value;
      // Empty is **not** "no plan". The chat source yields an empty list before
      // it has located the file and while the poll is paused behind the
      // terminal, and a conversation with no turns in it has no plan either
      // way — so both are the same honest answer and neither is a zero.
      if (messages == null || messages.isEmpty) {
        return const AgentPlanReading.absent(AgentPlanAbsence.notRead);
      }
      return agentPlanIn(messages);
    });
