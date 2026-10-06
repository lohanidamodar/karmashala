import 'package:karmashala_terminal_core/geometry.dart' show chatPaneSessionId;
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_location.dart';
import '../../environments/application/environments_controller.dart';
import '../../remote/application/machines_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_working_directory.dart';

/// Where [sessionId] runs, with the folder its agent runs in, or null while
/// its directory or environment row is not known: a name the row does not
/// give would be a guess.
final sessionLocationProvider = Provider.autoDispose
    .family<EnvironmentLocation?, String>((ref, sessionId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
        SessionChangeKind.workspace,
      });
      final row = ref.read(sessionsDataProvider).getById(sessionId);
      if (row == null) return null;
      final directory = sessionWorkingDirectoryOf(ref, row);
      if (directory == null) return null;
      for (final env in ref.watch(environmentsControllerProvider)) {
        if (env.id != directory.environmentId) continue;
        return locationOf(
          env,
          machine: ref.watch(activeMachineProvider),
          folder: directory.path.isEmpty ? null : directory.path,
        );
      }
      return null;
    });

/// Where the session pane [paneId] runs or reads — a chat pane's too — or
/// null for a pane holding no session.
final paneLocationProvider = Provider.autoDispose
    .family<EnvironmentLocation?, String>((ref, paneId) {
      final sessionId =
          chatPaneSessionId(paneId) ?? ref.watch(sessionOfPaneProvider(paneId));
      return sessionId == null
          ? null
          : ref.watch(sessionLocationProvider(sessionId));
    });
