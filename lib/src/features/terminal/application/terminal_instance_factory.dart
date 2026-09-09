part of 'terminal_sessions_controller.dart';

/// Whether new panes get OSC 133 shell integration.
///
/// A provider of its own rather than an inline settings read, so a test that
/// only wants a terminal does not have to stand up a database to get one —
/// the same seam `terminalInstanceFactoryProvider` already provides.
final shellIntegrationEnabledProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider).shellIntegrationEnabled,
);

/// Whether a restore puts a process back into the panes that had one.
///
/// The same seam and the same reason as [shellIntegrationEnabledProvider]: the
/// restore runs in `build`, and reading the setting directly would make every
/// terminal test stand up a settings store to open a pane.
final restoreLivePanesProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider).restoreLivePanes,
);

/// The production factory: each pane is backed by a real ConPTY, carrying the
/// user's environment variables.
///
/// The overlay is `ref.read` **inside** the closure rather than watched outside
/// it, which is what makes "a changed variable applies to the next pane, not to
/// the ones already running" true — and it is resolved once per launch, so the
/// per-keystroke path is untouched.
///
/// Every one of the five call sites goes through this provider, so this is the
/// only place the overlay has to be introduced.
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
              // Deployed or verified once per host per connection and shared by
              // every pane on it; null only when this app cannot reach SSH at
              // all, in which case the pane says nothing about a session host
              // it never asked about.
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
            workingDirectory:
                workingDirectory ?? agentLaunch?.workingDirectory,
            agentLaunch: agentLaunch,
            restoredScrollback: restoredScrollback,
            adoptTerminal: adoptTerminal,
          );
        }

        // Read here, per launch, for the same reason the environment overlay
        // is: a setting changed now applies to the next pane and not to the
        // ones already running, because an instance is built once and a running
        // shell cannot change which process owns it.
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
