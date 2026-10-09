import 'package:agent_cli/descriptors.dart' show PermissionRisk;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_git/repositories.dart' show samePath;
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../workspaces/data/workspace_data.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// Which checkout, and whose view of it: the session asking is not its own
/// neighbour.
typedef CheckoutOccupancyKey = ({EnvironmentPath directory, String? excluding});

/// **The live sessions that may write in a checkout** — one working tree, one
/// index and one branch between them. A session works in its own directory
/// (its worktree, or its repository root) and in every checkout attached to
/// it; one whose permission mode only reads is not counted. Advisory: nothing
/// stops a second writer.
final checkoutOccupantsProvider =
    Provider.family<List<CheckoutOccupant>, CheckoutOccupancyKey>((ref, key) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.placement,
        SessionChangeKind.settings,
        SessionChangeKind.workspace,
      });
      // A per-agent default mode decides a session that chose none.
      ref.watch(settingsControllerProvider);
      final sessions = ref.watch(sessionsDataProvider);
      final workspace = ref.watch(workspaceDataProvider);
      final installations = ref.watch(agentInstallationsDataProvider);
      final registry = ref.watch(agentRegistryProvider);
      final launcher = ref.read(sessionLauncherProvider);

      Iterable<EnvironmentPath> directoriesOf(Session session) sync* {
        final own =
            session.workingDirectory ??
            session.worktree ??
            workspace.repository(session.repositoryId)?.path;
        if (own != null) yield own;
        for (final link in sessions.linksFor(session.id)) {
          if (link.isPrimary) continue;
          if (workspace.repository(link.repositoryId) case final repository?) {
            yield repository.path;
          }
        }
      }

      bool mayWrite(Session session) {
        final effective = launcher.effectivePermissionFor(session.id);
        final risk = effective?.descriptor?.launch.permission.riskOf(
          effective.selection,
        );
        // A mode nobody established is not assumed to be harmless.
        return risk != PermissionRisk.readOnly;
      }

      return [
        for (final session in sessionsWritingIn(
          key.directory,
          among: sessions.getAll(),
          directoriesOf: directoriesOf,
          pathsMatch: samePath,
          mayWrite: mayWrite,
          excluding: key.excluding,
        ))
          CheckoutOccupant(
            session: session,
            agentName: switch (installations.getById(
              session.agentInstallationId,
            )) {
              final installation? => registry.displayNameFor(
                installation.agentId,
              ),
              null => null,
            },
          ),
      ];
    });

/// The others writing where [sessionId] works, for its badge: its own
/// directory, never a checkout it only has attached.
final sessionCheckoutSharersProvider =
    Provider.family<List<CheckoutOccupant>, String>((ref, sessionId) {
      ref.watchSession(sessionId);
      ref.watchSessionKinds(const {SessionChangeKind.workspace});
      final session = ref.watch(sessionsDataProvider).getById(sessionId);
      if (session == null) return const [];
      final directory =
          session.workingDirectory ??
          session.worktree ??
          ref
              .watch(workspaceDataProvider)
              .repository(session.repositoryId)
              ?.path;
      if (directory == null) return const [];
      return ref.watch(
        checkoutOccupantsProvider((directory: directory, excluding: sessionId)),
      );
    });
