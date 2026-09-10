import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../domain/session_last_active.dart';
import '../domain/session_launch.dart';
import '../domain/session_resume.dart';
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
///
/// Recomputed rather than polled. The two things it reads change on events we
/// already publish — the sessions revision and the terminal controller's
/// liveness map, which is republished exactly once when a process exits — and a
/// refusal appears at the moment of that exit. A poll would cost a screen read
/// per session per tick to learn nothing new.
final sessionWhereaboutsProvider = Provider.autoDispose
    .family<SessionWhereabouts, String>((ref, sessionId) {
      // Only this session's own row. The Explorer builds one of these per card,
      // so watching the whole revision meant a `getById` per visible row on
      // every rename — 100 reads at a hundred sessions, measured in
      // `session_signal_cost_test.dart`. This is the same narrowing
      // `terminalPaneLivenessProvider` below already gave the terminal half.
      ref.watchSession(sessionId);

      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return const SessionWhereabouts();

      final external = session.surface == SessionSurface.external;
      final paneId = session.paneId;
      // When the newest real evidence about this conversation was *written*.
      // Deliberately not "when we last polled": the poll is always fresh, and
      // showing its age beside a status would make a week-old transcript look
      // live. `agentEvidenceAt` is the one place that rule lives, so a source
      // that could tell us nothing contributes no timestamp anywhere.
      final lastSeen = agentEvidenceAt(
        ref.watch(agentSessionStatusProvider(sessionId)).asData?.value,
      );

      if (paneId == null) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }

      // A session card needs only its own pane. Watching the whole layout
      // made every visible card recompute when a tab was activated or an
      // unrelated process exited — O(session cards) work on the switch path.
      // The session revision above handles a row moving to another pane; this
      // narrow family handles the only terminal fact used below.
      final liveness = ref.watch(terminalPaneLivenessProvider(paneId));

      final instance = ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
      if (instance == null) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }
      if (liveness.isLive) {
        // The reading is kept, not dropped. "Running here" is the stronger
        // *claim*, and it still wins the subtitle — but a live session is the
        // one thing every list orders by, and it must not fall back to its own
        // birthday for want of a timestamp we already have.
        return SessionWhereabouts(hostedLive: true, lastSeen: lastSeen);
      }

      // A pane restored from disk has run nothing this launch, so its buffer
      // holds the *previous* run's output. A resume refusal in there says
      // another process held the conversation before the app restarted, which
      // is not evidence about now — and reading it would build the very buffer
      // `DormantTerminalInstance` keeps unparsed, on every Explorer tap.
      if (liveness == PaneLiveness.restored) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }

      // The pane is dead. Its last words are still in the buffer, and they may
      // be the agent explaining that somebody else holds the conversation, that
      // there is no conversation, or — for a launch that never got past its own
      // command line — that this installation does not have a mode we asked it
      // for. All three are read from one tail: the screen is scanned once, at
      // whichever window is largest, so a further question costs no further
      // read.
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

/// Whether the pane [paneId] is showing an agent's refusal to resume a
/// conversation another process holds.
///
/// Separate from [sessionWhereaboutsProvider] because the terminal panel draws
/// panes, not sessions: a pane knows its own launch and needs no session row to
/// explain itself.
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
///
/// The pane-level twin of [paneShowsResumeConflict], and it carries the same
/// two guards for the same reasons: a live pane has printed no post-mortem yet,
/// and a restored one's buffer is the *previous* run's.
///
/// Read by [reportRefusedLaunches] the moment a pane stops, which is the only
/// occasion this is asked — one tail per pane that actually died, and none for
/// an agent whose refusal nobody has read ([AgentRejectedValueRules.isEmpty]).
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
