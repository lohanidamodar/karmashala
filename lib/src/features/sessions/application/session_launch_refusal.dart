import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../domain/session_resume.dart';
import 'session_notice.dart';
import 'session_providers.dart';
import 'session_resume_providers.dart';

final _log = AppLogger.named('sessions.launch');

/// Tells the person whose session it was that the CLI refused their command
/// line, the moment the pane running it stops.
///
/// **The refusal was already parsed and already unread.** `RejectedValue` has
/// been read off a dead pane since the day Codex dropped `untrusted`, but the
/// only surface watching it is the Explorer card's subtitle — so a user looking
/// at the pane that just flashed and died saw "Session ended" and nothing else,
/// which is the whole failure the parse was written to end.
///
/// Posted as a [SessionNotice] rather than raised: the launch itself succeeded
/// (the process spawned; it exited while reading its own arguments), so there
/// is no call left to fail, and the notice bar is where this session's other
/// launch news already goes — `permission_mode_chip.dart` puts "the restart
/// failed" there.
///
/// **Costs one grid read per pane that actually died**, and none at all for an
/// agent whose refusal nobody has read: [paneRejectedValue] returns before
/// touching the buffer when the descriptor declares no pattern. Nothing polls —
/// this runs from the same liveness edge `SessionLivenessReconciler` already
/// reconciles on.
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
