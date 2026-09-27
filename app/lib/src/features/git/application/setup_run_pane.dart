import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';

/// Shows a worktree's setup or teardown command — which the server runs as a
/// session of its own, named like every hosted run (`hostedRunSessionId`) —
/// as a tab: its pane when one is already open, else an attach-only pane on
/// [paneId] (its output so far, live while it runs, its record once it
/// ended). Nothing is started: a session that is gone ends the pane.
void showSetupRun(Ref ref, String paneId) {
  final controller = ref.read(terminalSessionsControllerProvider.notifier);
  if (controller.instanceFor(paneId) != null) {
    controller.focusPane(paneId);
  } else {
    controller.openHostedRunTab(paneId: paneId, title: 'Worktree setup');
  }
  controller.showTerminalHere();
}

/// [showSetupRun], for a widget.
final setupRunPaneProvider = Provider<void Function(String paneId)>(
  (ref) =>
      (paneId) => showSetupRun(ref, paneId),
);
