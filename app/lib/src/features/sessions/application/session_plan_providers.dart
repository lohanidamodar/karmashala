import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/launch.dart';
import '../../../core/capabilities/capabilities.dart';
import '../data/server_transcripts.dart';
import 'session_chat_source.dart';
import 'session_chat_view_providers.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// How long a plan can stand still before it is worth pointing at. Fifteen
/// minutes, agenttrail's number (`0d5d151`); not a claim the agent is stuck.
const Duration kPlanGoesStaleAfter = Duration(minutes: 15);

/// Why there is no plan to draw. Four shapes, because they are four different
/// sentences and collapsing them is what makes an empty list a lie.
enum AgentPlanAbsence {
  /// **This agent keeps no plan we can read** — a capability answer, said in
  /// words rather than drawn as an empty list, which reads as "no work".
  agentPublishesNone,

  /// The agent does keep one, and has not written one in this conversation
  /// yet. An answer, not an absence of one.
  noneYet,

  /// There is no record of this session's turns we could read at all: no CLI
  /// id yet, an installation that is gone, or a pane that is not ours.
  noRecord,

  /// **There is a record and we have not read it**: the transcript is re-read
  /// only while a conversation is the surface in front.
  notRead,
}

/// One reading of an agent's own plan, with the age of the reading on it —
/// [writtenAt] is when the agent *wrote* it, never when we first saw it.
class AgentPlanReading {
  const AgentPlanReading.of(AgentPlan this.plan, {required this.writtenAt})
    : absence = null,
      refusal = '';

  /// There is nothing to draw, and [absence] says which nothing it is.
  /// [refusal] is the more specific sentence behind it when there is one.
  const AgentPlanReading.absent(
    AgentPlanAbsence this.absence, {
    this.refusal = '',
  }) : plan = null,
       writtenAt = null;

  final AgentPlan? plan;

  /// When the agent wrote this plan, or null when its line carried no
  /// timestamp — so nothing downstream may assume an age exists.
  final DateTime? writtenAt;

  final AgentPlanAbsence? absence;

  final String refusal;

  bool get hasPlan => plan != null;

  /// How old the plan is at [now], never negative and null when undated — a
  /// clock that runs ahead of ours is not a plan from the future.
  Duration? ageAt(DateTime now) {
    final at = writtenAt;
    if (at == null) return null;
    final elapsed = now.difference(at);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// Whether this plan has work left and has not moved for
  /// [kPlanGoesStaleAfter]. A finished plan is completed work, not stalled.
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

/// **The plan [messages] leaves standing.** Last one wins, measured: both CLIs
/// resend the whole list, so folding would draw items already dropped.
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

/// **The plan one session's agent is working to**, off the transcript the
/// conversation already watches. Nothing polls, and an idle plan still counts.
final sessionAgentPlanProvider = Provider.autoDispose
    .family<AgentPlanReading, String>((ref, sessionId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
      });
      final row = ref.read(sessionsDataProvider).getById(sessionId);
      if (row == null) {
        return const AgentPlanReading.absent(AgentPlanAbsence.noRecord);
      }

      // The capability answer comes first and costs nothing: an agent that
      // keeps no plan must never reach a transcript subscription to learn that.
      final agentId = ref
          .read(agentInstallationsDataProvider)
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

      // **Which nothing, in the reading's own words**: an unreadable store and
      // a transcript that is simply not there are different sentences.
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
      // it has located the file, and a conversation with no turns has none.
      if (messages == null || messages.isEmpty) {
        return const AgentPlanReading.absent(AgentPlanAbsence.notRead);
      }
      final reading = agentPlanIn(messages);
      if (reading.hasPlan) return reading;
      // From a server, [messages] are the tail: an older plan is in the
      // window's digest of the rows before it (Stage 0 step 8).
      final window = ref.read(capabilitiesProvider).chatViaServer
          ? ref.read(serverTranscriptsProvider).windowFor(sessionId, messages)
          : null;
      if (window == null) return reading;
      final older = window.olderPlan;
      if (older != null) return agentPlanIn([older]);
      if (window.olderUnknown) {
        return const AgentPlanReading.absent(
          AgentPlanAbsence.noneYet,
          refusal:
              'Only the latest part of this conversation is loaded from its '
              'server, and it holds no plan. Scroll back in Chat to look '
              'further.',
        );
      }
      return reading;
    });
