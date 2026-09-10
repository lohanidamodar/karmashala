import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import '../../terminal/data/terminal_grid_text.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/launch.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'session_signals.dart';

/// The agent descriptor behind session [sessionId], or null.
AgentDescriptor? sessionDescriptor(Ref ref, String agentInstallationId) {
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(agentInstallationId)
      ?.agentId;
  return agentId == null ? null : ref.read(agentRegistryProvider).byId(agentId);
}

/// What we can honestly say about where session [sessionId]'s process is.
/// Recomputed, not polled — a poll reads a screen per session to learn nothing.
final sessionWhereaboutsProvider = Provider.autoDispose
    .family<SessionWhereabouts, String>((ref, sessionId) {
      // Only this session's own row: the Explorer builds one per card, so the
      // whole revision meant a `getById` per visible row on every rename.
      ref.watchSession(sessionId);

      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return const SessionWhereabouts();

      final external = session.surface == SessionSurface.external;
      final paneId = session.paneId;
      // When the evidence was *written*, not when we last polled: the poll is
      // always fresh, and its age would make a week-old transcript look live.
      final lastSeen = agentEvidenceAt(
        ref.watch(agentSessionStatusProvider(sessionId)).asData?.value,
      );

      if (paneId == null) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }

      // A session card needs only its own pane: watching the layout made every
      // card recompute when a tab was activated or another process exited.
      final liveness = ref.watch(terminalPaneLivenessProvider(paneId));

      final instance = ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
      if (instance == null) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }
      if (liveness.isLive) {
        // The reading is kept: a live session is what every list orders by,
        // and it must not fall back to its birthday for want of a timestamp.
        return SessionWhereabouts(hostedLive: true, lastSeen: lastSeen);
      }

      // A restored pane's buffer holds the *previous* run's output, and
      // reading it builds the buffer `DormantTerminalInstance` keeps unparsed.
      if (liveness == PaneLiveness.restored) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }

      // The pane is dead, and its last words may name a holder, no conversation
      // or a rejected flag. All three come from one tail, at the widest window.
      final descriptor = sessionDescriptor(ref, session.agentInstallationId);
      final conflict =
          descriptor?.launch.resumeConflict ?? const AgentResumeConflictRules();
      final missing =
          descriptor?.launch.missingConversation ??
          const AgentMissingConversationRules();
      final rejected =
          descriptor?.launch.rejectedValue ??
          const AgentRejectedValueRules.none();
      final tail = terminalTailLines(
        instance.terminal,
        lines: [
          conflict.scanLines,
          missing.scanLines,
          rejected.scanLines,
        ].reduce((a, b) => a > b ? a : b),
      );
      return SessionWhereabouts(
        external: external,
        refusedResume: showsResumeConflict(descriptor, tail),
        conversationMissing: missing.matchedBy(tail),
        rejectedValue: rejected.matchedBy(tail),
        lastSeen: lastSeen,
      );
    });

/// Whether the pane [paneId] shows an agent refusing to resume a conversation
/// another process holds — a pane knows its own launch and needs no row.
bool paneShowsResumeConflict(Ref ref, String paneId) {
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  final agentId = instance?.agentLaunch?.agentId;
  if (instance == null || agentId == null) return false;
  if (instance.liveness.value.isLive) return false;
  // Same rule as [sessionWhereaboutsProvider]: a restored pane's buffer is the
  // last run's, and reading it would parse scrollback the restore kept whole.
  if (instance.liveness.value == PaneLiveness.restored) return false;
  final descriptor = ref.read(agentRegistryProvider).byId(agentId);
  return showsResumeConflict(
    descriptor,
    terminalTailLines(
      instance.terminal,
      lines: descriptor?.launch.resumeConflict.scanLines ?? 30,
    ),
  );
}

/// The command-line value the pane [paneId] shows its agent refusing, or null.
/// Read by [reportRefusedLaunches] the moment a pane stops, and nowhere else.
RejectedValue? paneRejectedValue(Ref ref, String paneId) {
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  final agentId = instance?.agentLaunch?.agentId;
  if (instance == null || agentId == null) return null;
  if (instance.liveness.value.isLive) return null;
  if (instance.liveness.value == PaneLiveness.restored) return null;
  final rules = ref.read(agentRegistryProvider).byId(agentId)?.launch
      .rejectedValue;
  if (rules == null || rules.isEmpty) return null;
  return rules.matchedBy(
    terminalTailLines(instance.terminal, lines: rules.scanLines),
  );
}
