import 'package:karmashala_terminal_core/geometry.dart' show chatPaneSessionId;
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// The agent [sessionId] runs now, as its installation names it; null for a
/// row or an installation not delivered yet. Follows a switch in place.
final sessionAgentIdProvider = Provider.autoDispose.family<String?, String>((
  ref,
  sessionId,
) {
  // A switch in place moves the row's installation, told as `placement`.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.placement,
  });
  final row = ref.read(sessionsDataProvider).getById(sessionId);
  if (row == null) return null;
  final installations = ref.watch(agentInstallationsDataProvider);
  final agentId = installations.getById(row.agentInstallationId)?.agentId;
  if (agentId == null) {
    // The installation can arrive after the row on a fresh connection.
    final arrivals = installations.changes.listen((_) => ref.invalidateSelf());
    ref.onDispose(arrivals.cancel);
  }
  return agentId;
});

/// The agent of the session pane [paneId] runs or reads — a chat pane's too —
/// or null for a pane holding no session.
final paneAgentIdProvider = Provider.autoDispose.family<String?, String>((
  ref,
  paneId,
) {
  final sessionId =
      chatPaneSessionId(paneId) ?? ref.watch(sessionOfPaneProvider(paneId));
  return sessionId == null
      ? null
      : ref.watch(sessionAgentIdProvider(sessionId));
});
