import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../application/session_engine_provider.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/session_launcher.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';
import '../application/session_status_providers.dart';

/// Stops the process behind [sessionId] wherever it runs — this app's engine,
/// a live terminal pane of ours, or the server's terminal with no pane showing
/// it — and tells every list the row moved. False when nothing ran it.
///
/// The one verb the status line's Stop and the session rows' End share: the
/// pane or the server goes through [SessionHostedVerbs.endRunning], the same
/// path `session_end` takes. The transcript survives; the row settles as
/// cancelled once the host reports the close, and a click resumes it.
Future<bool> endSessionProcess(WidgetRef ref, String sessionId) async {
  final engine = ref.read(sessionEngineProvider);
  bool ended;
  if (engine.isActive(sessionId)) {
    await engine.stop(sessionId);
    ended = true;
  } else {
    ended =
        await ref.read(sessionLauncherProvider).endRunning(sessionId) != null;
  }
  ref.publishSessionChange(SessionChange.statusChanged(sessionId));
  return ended;
}

/// Whether any process runs [sessionId] right now: this app's engine, a live
/// terminal pane of ours, or the server's terminal with no pane showing it.
///
/// One reading for every surface that must not trust a status badge alone — a
/// killed agent's last report can still say "working". Watches placement and
/// the pane's liveness so a caller rebuilds when the process starts or exits;
/// the engine and host readings are sampled on those rebuilds.
bool sessionHasLiveProcess(WidgetRef ref, String sessionId) {
  ref.watch(placedSessionIdsProvider);
  final paneId = ref.read(sessionsDataProvider).getById(sessionId)?.paneId;
  if (paneId != null &&
      ref.watch(terminalPaneLivenessProvider(paneId)).isLive) {
    return true;
  }
  return ref.read(sessionEngineProvider).isActive(sessionId) ||
      ref.read(sessionLauncherProvider).heldByHostOnly(sessionId);
}

/// Whether anything runs [sessionId] right now — what [endSessionProcess]
/// could end. Read, not watched: for a menu deciding what to offer as it
/// opens. A row that draws the × watches [sessionHasLiveProcess] instead.
bool sessionRunsNow(WidgetRef ref, String sessionId) {
  final launcher = ref.read(sessionLauncherProvider);
  return launcher.livePaneFor(sessionId) != null ||
      ref.read(sessionEngineProvider).isActive(sessionId) ||
      launcher.heldByHostOnly(sessionId);
}

/// Whether ending [sessionId] now would cut a turn short: the agent is
/// working, or stopped on a question or an approval. Ending an agent idle at
/// its prompt loses nothing — the conversation stays resumable — so only
/// these ask first.
bool sessionIsMidTurn(WidgetRef ref, String sessionId) {
  final status = ref.read(sessionActivityLookupProvider)(sessionId);
  return status == AgentActivityStatus.working ||
      status == AgentActivityStatus.awaitingApproval;
}

/// "End session" from a session row — its menu or its ×. Asks first only when
/// the agent is mid-turn; says a refusal or a failure in words.
Future<void> endSessionFromRow(
  BuildContext context,
  WidgetRef ref,
  String sessionId, {
  required String title,
}) async {
  if (sessionIsMidTurn(ref, sessionId)) {
    final confirmed = await showConfirmDialog(
      context,
      title: 'End "$title"?',
      message:
          'Its agent is in the middle of a turn. Ending stops the process '
          'now, and the turn in flight is lost. The conversation itself stays: '
          'open the session again to resume it.',
      confirmLabel: 'End session',
    );
    if (!confirmed || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  String? say;
  try {
    if (!await endSessionProcess(ref, sessionId)) {
      say = 'Nothing is running that session, so there is nothing to end.';
    }
  } on Object catch (error) {
    say =
        'Could not end that session: '
        '${error is StateError ? error.message : error}';
  }
  if (say != null) messenger?.showSnackBar(SnackBar(content: Text(say)));
}
