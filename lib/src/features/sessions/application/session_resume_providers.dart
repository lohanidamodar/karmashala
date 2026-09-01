import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/data/resume_conflict_source.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_status.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../domain/session_launch.dart';
import '../domain/session_resume.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'session_ui_providers.dart';

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
      ref.watch(sessionsRevisionProvider);
      ref.watch(terminalSessionsControllerProvider);

      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) return const SessionWhereabouts();

      final external = session.surface == SessionSurface.external;
      final paneId = session.paneId;
      // When the newest real evidence about this conversation was *written*.
      // Deliberately not "when we last polled": the poll is always fresh, and
      // showing its age beside a status would make a week-old transcript look
      // live. A source that could tell us nothing (`AgentStatusSource.none`)
      // contributes no timestamp at all, which renders as no age rather than as
      // a zero.
      final report = ref
          .watch(agentSessionStatusProvider(sessionId))
          .asData
          ?.value;
      final lastSeen = report == null || report.source == AgentStatusSource.none
          ? null
          : report.evidenceAt;

      if (paneId == null) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }

      final instance = ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
      if (instance == null) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }
      if (instance.liveness.value.isLive) {
        return const SessionWhereabouts(hostedLive: true);
      }

      // A pane restored from disk has run nothing this launch, so its buffer
      // holds the *previous* run's output. A resume refusal in there says
      // another process held the conversation before the app restarted, which
      // is not evidence about now — and reading it would build the very buffer
      // `DormantTerminalInstance` keeps unparsed, on every Explorer tap.
      if (instance.liveness.value == PaneLiveness.restored) {
        return SessionWhereabouts(external: external, lastSeen: lastSeen);
      }

      // The pane is dead. Its last words are still in the buffer, and for a
      // launch that was a resume they may be the agent explaining that somebody
      // else holds the conversation — or that there is no conversation. Both
      // are read from one tail: the screen is scanned once, at whichever
      // window is larger, so a second question costs no second read.
      final descriptor = sessionDescriptor(ref, session.agentInstallationId);
      final conflict =
          descriptor?.launch.resumeConflict ??
          const AgentResumeConflictRules();
      final missing =
          descriptor?.launch.missingConversation ??
          const AgentMissingConversationRules();
      final tail = terminalTailLines(
        instance.terminal,
        lines: conflict.scanLines > missing.scanLines
            ? conflict.scanLines
            : missing.scanLines,
      );
      return SessionWhereabouts(
        external: external,
        refusedResume: showsResumeConflict(descriptor, tail),
        conversationMissing: missing.matchedBy(tail),
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
