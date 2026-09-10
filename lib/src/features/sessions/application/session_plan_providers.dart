import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import '../domain/session_launch.dart';
import 'session_chat_source.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// **How long a plan can stand still before it is worth pointing at.** Fifteen
/// minutes, borrowed from agenttrail (`0d5d151`) rather than invented, because
/// the number has been lived with. It is **not** a claim that the agent is
/// stuck — one item can legitimately take an hour; it says only which of four
/// has not moved.
const Duration kPlanGoesStaleAfter = Duration(minutes: 15);

/// Why there is no plan to draw. Four shapes, because they are four different
/// sentences and collapsing them is what makes an empty list a lie.
enum AgentPlanAbsence {
  /// **This agent keeps no plan we can read** — a capability answer, measured
  /// per CLI and carried on the descriptor with its evidence. The panel says so
  /// in words rather than drawing an empty list, which reads as "no work".
  agentPublishesNone,

  /// The agent does keep one, and has not written one in this conversation
  /// yet. An answer, not an absence of one.
  noneYet,

  /// There is no record of this session's turns we could read at all — no CLI
  /// session id yet, an installation that is gone, a session running somewhere
  /// that is not one of our panes.
  noRecord,

  /// **There is a record and we have not read it.** The transcript is re-read
  /// only while a conversation is the surface in front, and nothing here arms a
  /// second poll to close that gap.
  notRead,
}

/// **One reading of an agent's own plan, with the age of the reading on it** —
/// a plan that has been overtaken looks exactly like a current one, and a
/// reader glancing at four of them cannot tell which is which without the age.
///
/// [writtenAt] is when the agent *wrote* the plan, from the transcript line's
/// own timestamp, never a first-sighting time. One age rather than two: a plan
/// we hold can never be newer than the last read, so the written time is
/// already the conservative of the pair. Real equality, so a re-parse that
/// found the same plan leaves the panel asleep.
class AgentPlanReading {
  const AgentPlanReading.of(AgentPlan this.plan, {required this.writtenAt})
    : absence = null,
      refusal = '';

  /// There is nothing to draw, and [absence] says which nothing it is.
  /// [refusal] is the more specific sentence behind it when there is one.
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
  /// [kPlanGoesStaleAfter]. False for a finished plan however old it is: a list
  /// whose items are all done is completed work, not stalled work.
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
/// written.** One walk of a list the parse already produced; nothing here opens
/// a file.
///
/// Last one wins, and that is measured rather than assumed: both CLIs that keep
/// a plan resend the whole list on every change, so folding would draw items
/// the agent had already dropped — one real session goes 15 items → 4 → 11 and
/// ends at 1. A row whose plan failed to parse contributes **nothing** rather
/// than an empty plan, so a changed format leaves the last plan we understood
/// on screen.
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
/// pane. Derived entirely from the transcript the conversation is already
/// watching, so the panel, the conversation and the activity strip share one
/// subscription, one poll and one parse; **nothing here polls**. That
/// subscription only works while a conversation is the surface in front, so
/// behind the terminal this answers [AgentPlanAbsence.notRead]. Not gated on
/// the session *working*: a finished plan on an idle agent is worth as much as
/// a live one, and telling those apart is what the panel exists for.
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
      // `SessionChatView` probe — to find that out.
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

      // **Which nothing, in the reading's own words**: `SessionChatView.reason`
      // tells an unreadable store from a session whose transcript file is
      // simply not there, where the panel used to say both at once.
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
      // Empty is **not** "no plan": the chat source yields an empty list before
      // it has located the file and while the poll is paused behind the
      // terminal, and a conversation with no turns has no plan either way.
      if (messages == null || messages.isEmpty) {
        return const AgentPlanReading.absent(AgentPlanAbsence.notRead);
      }
      return agentPlanIn(messages);
    });
