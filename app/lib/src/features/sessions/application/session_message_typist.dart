import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_resume_providers.dart';

/// The app's [SessionMessageTypist]: its own panes' screens and keys. A
/// session the server holds is typed into by the server itself.
final sessionMessageTypistProvider = Provider<SessionMessageTypist>((ref) {
  return SessionMessageTypist(
    readScreen: (sessionId) {
      final paneId = ref.read(sessionLauncherProvider).livePaneFor(sessionId);
      if (paneId == null) return null;
      final instance = ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
      if (instance == null) return null;
      return terminalTailLines(instance.terminal, lines: kMenuScreenRows);
    },
    markersFor: (sessionId) {
      final session = ref.read(sessionsDataProvider).getById(sessionId);
      if (session == null) return null;
      return sessionDescriptor(
        ref,
        session.agentInstallationId,
      )?.menus?.markers;
    },
    type: (sessionId, text) =>
        ref.read(sessionLauncherProvider).typeInto(sessionId, text),
    press: (sessionId, keys) =>
        ref.read(sessionLauncherProvider).pressKeys(sessionId, keys),
  );
});
