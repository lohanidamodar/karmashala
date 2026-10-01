import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../../explorer/application/agent_state_providers.dart';
import '../application/session_engine_provider.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/session_launcher.dart';
import '../application/session_signals.dart';
import '../application/session_status_providers.dart';
import 'session_transcript_view.dart' show sessionTerminalPane;

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
  // This window's pane, found by what it runs when the row names another
  // window's: off the row alone, the × went missing from a running session.
  final paneId = sessionTerminalPane(ref, sessionId);
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

/// Why ending [sessionId] now would lose something, in words for the confirm
/// dialog; null when it would not. An agent known to be idle at its prompt,
/// or already failed, loses nothing — the conversation stays resumable — so
/// only that ends without asking. Waiting on the user (from the agent's own
/// status or the attention feed), working, and a status nothing could read
/// all ask first.
String? endSessionWarning(WidgetRef ref, String sessionId) {
  const resumable =
      'The conversation itself stays: open the session again to resume it.';
  final status = ref.read(sessionActivityLookupProvider)(sessionId);
  if (status == AgentActivityStatus.awaitingApproval ||
      ref.read(needsYouProvider).containsKey(sessionId)) {
    return 'Its agent is waiting for you — a question or an approval. Ending '
        'stops the process now, and what it asked is dropped. $resumable';
  }
  return switch (status) {
    AgentActivityStatus.working =>
      'Its agent is in the middle of a turn. Ending stops the process now, '
          'and the turn in flight is lost. $resumable',
    AgentActivityStatus.unknown =>
      'Karmashala cannot tell whether its agent is busy. Ending stops the '
          'process now, and any turn in flight is lost. $resumable',
    AgentActivityStatus.idle ||
    AgentActivityStatus.failed ||
    AgentActivityStatus.awaitingApproval => null,
  };
}

/// "End session" from a session row — its menu or its ×. Asks first unless
/// the agent is known to be idle ([endSessionWarning]); says a refusal or a
/// failure in words.
Future<void> endSessionFromRow(
  BuildContext context,
  WidgetRef ref,
  String sessionId, {
  required String title,
}) async {
  final warning = endSessionWarning(ref, sessionId);
  if (warning != null) {
    final confirmed = await showConfirmDialog(
      context,
      title: 'End "$title"?',
      message: warning,
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
