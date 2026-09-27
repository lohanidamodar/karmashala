import 'package:karmashala_terminal_core/profiles.dart';
import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../../terminal/application/terminal_profiles.dart';
import '../../terminal/application/terminal_sessions_controller.dart';

/// Shows a worktree's setup or teardown command — which the server runs as a
/// session of its own, named like a pane — as a tab: its pane when one is
/// already open, else a new pane on [paneId] that **attaches** to the
/// server's session (its output so far, live while it runs, its record once
/// it ended). Nothing is started: the host opens only a session it lacks.
void showSetupRun(Ref ref, String paneId) {
  final controller = ref.read(terminalSessionsControllerProvider.notifier);
  if (controller.instanceFor(paneId) != null) {
    controller.focusPane(paneId);
  } else {
    controller.openTab(
      resolveTerminalProfile(
        ref.read(settingsControllerProvider).defaultTerminalProfileId,
        ref.read(terminalProfilesProvider),
      ),
      adoptPaneId: paneId,
    );
  }
  controller.showTerminalHere();
}

/// [showSetupRun], for a widget.
final setupRunPaneProvider = Provider<void Function(String paneId)>(
  (ref) => (paneId) => showSetupRun(ref, paneId),
);
