import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../domain/session_resume.dart';
import 'session_notice.dart';
import 'session_providers.dart';
import 'session_resume_providers.dart';

final _log = AppLogger.named('sessions.launch');

/// Tells the person whose session it was that the CLI refused their command
/// line, the moment the pane running it stops.
///
/// **The refusal was already parsed and already unread**: the only surface
/// watching `RejectedValue` was the Explorer card's subtitle, so a user looking
/// at the pane that just flashed and died saw "Session ended" and nothing else.
///
/// Posted as a [SessionNotice] rather than raised — the launch itself
/// succeeded, and the process exited while reading its own arguments. Costs one
/// grid read per pane that actually died, and none for an agent whose refusal
/// nobody has read; nothing polls.
void reportRefusedLaunches(Ref ref, Iterable<String> stoppedPaneIds) {
  final refusals = <String, ({String pane, RejectedValue value})>{};
  for (final paneId in stoppedPaneIds) {
    final rejected = paneRejectedValue(ref, paneId);
    if (rejected == null) continue;
    refusals[paneId] = (pane: paneId, value: rejected);
  }
  if (refusals.isEmpty) return;

  final controller = ref.read(terminalSessionsControllerProvider.notifier);
  final registry = ref.read(agentRegistryProvider);
  for (final session in ref.read(sessionDaoProvider).getByPaneIds(
    refusals.keys,
  )) {
    final refusal = refusals[session.paneId];
    if (refusal == null) continue;
    final agentId = controller.instanceFor(refusal.pane)?.agentLaunch?.agentId;
    final name = registry.byId(agentId ?? '')?.displayName ?? 'agent';
    final sentence = rejectedValueNotice(name, refusal.value);
    _log.warning(
      'Refused ${session.id} at its command line: agent=$agentId '
      "value='${refusal.value.value}' flag='${refusal.value.flag}' "
      'offered=${refusal.value.alternativesLabel} pane=${refusal.pane}',
    );
    ref
        .read(sessionNoticesProvider.notifier)
        .post(
          session.id,
          SessionNotice(message: sentence, tone: SessionNoticeTone.warning),
        );
  }
}
