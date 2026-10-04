import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal;
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'ask_resolutions.dart' show ownPromptAnswersProvider;
import 'session_input.dart';

/// **Stops a session's running turn** the way its own terminal would: an Esc
/// pressed by the server when it runs the session, else typed into the
/// agent's pane here. Answers why it could not, or null when it was sent.
/// The chat's Stop, its Esc, and a plan card's Stop all come through here.
final sessionTurnInterruptProvider =
    Provider<Future<String?> Function(String sessionId)>(
      (ref) => (sessionId) async {
        if (!ref.read(capabilitiesProvider).maySend) return kPromptNotGranted;
        // An Esc closes an open prompt too: not one answered elsewhere.
        ref.read(ownPromptAnswersProvider).note(sessionId);
        final input = ref.read(sessionInputProvider);
        if (input.viaServer) {
          try {
            // One the server does not run may still run in a pane here.
            if (await input.interrupt(sessionId)) return null;
          } on SessionPromptRefusal catch (refusal) {
            return 'Could not stop it: ${refusal.message}';
          }
        }
        final paneId = ref.read(paneSessionsProvider).paneOf(sessionId);
        final terminals = ref.read(terminalSessionsControllerProvider.notifier);
        final live =
            paneId != null &&
            ref
                .read(terminalSessionsControllerProvider)
                .livenessOf(paneId)
                .isLive;
        final instance = paneId == null ? null : terminals.instanceFor(paneId);
        if (!live || instance == null) {
          return 'No live terminal runs this session, so there is nothing to '
              'stop.';
        }
        instance.terminal.textInput('\x1b');
        return null;
      },
    );
