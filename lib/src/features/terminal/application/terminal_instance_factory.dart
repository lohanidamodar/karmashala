part of 'terminal_sessions_controller.dart';

/// Whether new panes get OSC 133 shell integration. Its own provider so a test
/// that only wants a terminal need not stand up a database.
final shellIntegrationEnabledProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider).shellIntegrationEnabled,
);

/// Whether a restore puts a process back into the panes that had one. Its own
/// provider for [shellIntegrationEnabledProvider]'s reason.
final restoreLivePanesProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider).restoreLivePanes,
);

/// The production factory: a real ConPTY per pane, carrying the user's
/// variables. The overlay is read *inside* the closure, so a change is next-pane.
final terminalInstanceFactoryProvider = Provider<TerminalInstanceFactory>(
  (ref) =>
      ({
        required String id,
        required TerminalProfile profile,
        String? workingDirectory,
        String? restoredScrollback,
        bool shellIntegration = false,
        AgentPaneLaunch? agentLaunch,
        Terminal? adoptTerminal,
      }) {
        final sshHostId = profile.sshHostId ?? agentLaunch?.sshHostId;
        if (sshHostId != null) {
          final host = ref.read(sshHostDaoProvider).getById(sshHostId);
          if (host != null) {
            final pool = ref.read(sshConnectionPoolProvider);
            return SshTerminalInstance(
              id: id,
              title: agentLaunch?.title ?? 'SSH: ${host.name}',
              profileId: profile.id,
              host: host,
              connection: pool.forHostId(host.id),
              // Deployed or verified once per host per connection and shared
              // by every pane on it; null only when SSH is unreachable.
              hostAccess: ref.read(hostSessionAccessLookupProvider)(host),
              workingDirectory:
                  workingDirectory ?? agentLaunch?.workingDirectory,
              agentLaunch: agentLaunch,
              adoptTerminal: adoptTerminal,
              restoredScrollback: restoredScrollback,
            );
          }
          return ErrorTerminalInstance(
            id: id,
            title: agentLaunch?.title ?? 'SSH terminal',
            profileId: profile.id,
            message: 'The saved SSH host "$sshHostId" no longer exists.',
            workingDirectory: workingDirectory ?? agentLaunch?.workingDirectory,
            agentLaunch: agentLaunch,
            restoredScrollback: restoredScrollback,
            adoptTerminal: adoptTerminal,
          );
        }

        // Per launch, like the environment overlay: a running shell cannot
        // change which process owns it, so a setting changed now applies to the
        // next pane only.
        final hostAccess = ref.read(hostBackedLocalPanesProvider)
            ? ref.read(localHostSessionAccessProvider)
            : null;
        if (hostAccess != null) {
          return createHostTerminalInstance(
            id: id,
            profile: profile,
            access: hostAccess,
            workingDirectory: workingDirectory,
            restoredScrollback: restoredScrollback,
            agentLaunch: agentLaunch,
            adoptTerminal: adoptTerminal,
            environmentOverlay: ref.read(terminalEnvOverlayProvider),
          );
        }

        return createPtyTerminalInstance(
          id: id,
          profile: profile,
          workingDirectory: workingDirectory,
          restoredScrollback: restoredScrollback,
          shellIntegration: shellIntegration,
          agentLaunch: agentLaunch,
          adoptTerminal: adoptTerminal,
          environmentOverlay: ref.read(terminalEnvOverlayProvider),
        );
      },
);
