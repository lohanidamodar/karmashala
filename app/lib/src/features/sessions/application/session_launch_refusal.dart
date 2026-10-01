import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'session_notice.dart';
import 'session_resume_providers.dart';

final _log = AppLogger.named('sessions.launch');

/// Tells the person whose session it was that the CLI refused their command
/// line, the moment its pane stops — a notice, because the launch itself ran.
void reportRefusedLaunches(Ref ref, Iterable<String> stoppedPaneIds) {
  final refusals = <String, ({String pane, RejectedValue value})>{};
  for (final paneId in stoppedPaneIds) {
    final rejected = paneRejectedValue(ref, paneId);
    if (rejected == null) continue;
    refusals[paneId] = (pane: paneId, value: rejected);
  }
  if (refusals.isEmpty) return;

  final controller = ref.read(terminalSessionsControllerProvider.notifier);
  final panes = ref.read(paneSessionsProvider);
  final registry = ref.read(agentRegistryProvider);
  for (final refusal in refusals.values) {
    final sessionId = panes.sessionOf(refusal.pane);
    if (sessionId == null) continue;
    final agentId = controller.instanceFor(refusal.pane)?.agentLaunch?.agentId;
    final name = registry.byId(agentId ?? '')?.displayName ?? 'agent';
    final sentence = rejectedValueNotice(name, refusal.value);
    _log.warning(
      'Refused $sessionId at its command line: agent=$agentId '
      "value='${refusal.value.value}' flag='${refusal.value.flag}' "
      'offered=${refusal.value.alternativesLabel} pane=${refusal.pane}',
    );
    ref
        .read(sessionNoticesProvider.notifier)
        .post(
          sessionId,
          SessionNotice(message: sentence, tone: SessionNoticeTone.warning),
        );
  }
}

/// Pane ids that were running in [previous] and are not in [next] — pure, so
/// a listener does work only when one stopped.
Set<String> panesThatStoppedRunning(
  Map<String, PaneLiveness>? previous,
  Map<String, PaneLiveness> next,
) {
  if (previous == null || previous.isEmpty) return const {};
  return {
    for (final entry in previous.entries)
      if (entry.value.isLive && !(next[entry.key]?.isLive ?? false)) entry.key,
  };
}

/// Pane ids running in [next] that were not running in [previous] — every
/// running one when there was no previous state.
Set<String> panesThatStartedRunning(
  Map<String, PaneLiveness>? previous,
  Map<String, PaneLiveness> next,
) => {
  for (final entry in next.entries)
    if (entry.value.isLive && !(previous?[entry.key]?.isLive ?? false))
      entry.key,
};

/// Reports a refused launch the moment its pane stops — the one edge on which
/// the CLI's refusal is readable. **Watched, not read**: Riverpod 3 pauses a
/// provider nobody listens to. A row's lifecycle status is never written here
/// (the server records it).
final refusedLaunchReporterProvider = Provider<void>((ref) {
  ref.listen(terminalSessionsControllerProvider, (previous, next) {
    final stopped = panesThatStoppedRunning(previous?.liveness, next.liveness);
    if (stopped.isNotEmpty) reportRefusedLaunches(ref, stopped);
  });
});
