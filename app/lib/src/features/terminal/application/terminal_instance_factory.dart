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

/// A pane on a session the server hosts — a Flutter run or build, a
/// worktree's setup (slices 3b, 3d) — attaching only, never starting one; null
/// when this machine's server is not reachable for panes.
typedef HostedRunPaneFactory =
    TerminalInstance? Function({required String id, required String title});

final hostedRunPaneFactoryProvider = Provider<HostedRunPaneFactory>(
  (ref) => ({required String id, required String title}) {
    final access = ref.read(localHostSessionAccessProvider);
    if (access == null) return null;
    return HostTerminalInstance(
      id: id,
      title: title,
      // What a restore reopens this pane as, when the run is long gone.
      profileId: resolveTerminalProfile(
        ref.read(settingsControllerProvider).defaultTerminalProfileId,
        ref.read(terminalProfilesProvider),
      ).id,
      access: access,
      sessionId: hostedRunSessionId(id),
    );
  },
);

/// A restored pane put back on the server session its pane id names,
/// **attaching only** (slice 5a): a session still running is re-attached, an
/// ended one the server kept shows its record and exit, and one it no
/// longer holds ends the pane with its stored history — the pane's Start is
/// what asks for a new one. Null where no server can be reached for panes.
typedef RestoredPaneFactory =
    TerminalInstance? Function({
      required String id,
      required TerminalProfile profile,
      String? workingDirectory,
      String? restoredScrollback,
      AgentPaneLaunch? agentLaunch,
      Terminal? adoptTerminal,
    });

final restoredPaneFactoryProvider = Provider<RestoredPaneFactory>(
  (ref) =>
      ({
        required String id,
        required TerminalProfile profile,
        String? workingDirectory,
        String? restoredScrollback,
        AgentPaneLaunch? agentLaunch,
        Terminal? adoptTerminal,
      }) {
        if (profile.sshHostId != null ||
            agentLaunch?.sshHostId != null ||
            ref.read(localHostSessionAccessProvider) == null) {
          return null;
        }
        return _serverPane(
          ref,
          id: id,
          profile: profile,
          workingDirectory: workingDirectory,
          restoredScrollback: restoredScrollback,
          agentLaunch: agentLaunch,
          adoptTerminal: adoptTerminal,
          shellIntegration: false,
          attachOnly: true,
        );
      },
);

/// The production factory: an SSH pane on this app's own connection (until
/// slice 5d), and **every other pane a terminal the server runs** — asked
/// for with `terminals.open`, then attached to by id. No in-app PTY, and no
/// fallback to one.
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
          final host = ref.read(sshHostsDataProvider).getById(sshHostId);
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
        return _serverPane(
          ref,
          id: id,
          profile: profile,
          workingDirectory: workingDirectory,
          restoredScrollback: restoredScrollback,
          agentLaunch: agentLaunch,
          adoptTerminal: adoptTerminal,
          shellIntegration: shellIntegration,
          attachOnly: false,
        );
      },
);

/// A pane on the server's terminal for [id]: asked for with `terminals.open`
/// (the server builds the launch on its own OS, with its vault) unless
/// [attachOnly], then attached to by session id.
TerminalInstance _serverPane(
  Ref ref, {
  required String id,
  required TerminalProfile profile,
  required String? workingDirectory,
  required String? restoredScrollback,
  required AgentPaneLaunch? agentLaunch,
  required Terminal? adoptTerminal,
  required bool shellIntegration,
  required bool attachOnly,
}) {
  final title = agentLaunch?.title ?? agentLaunch?.agentId ?? profile.label;
  final profileId = agentLaunch?.profileId ?? profile.id;
  final directory = workingDirectory ?? agentLaunch?.workingDirectory;
  final access = ref.read(localHostSessionAccessProvider);
  if (access == null) {
    return ErrorTerminalInstance(
      id: id,
      title: title,
      profileId: profileId,
      message:
          'No Karmashala server can be reached from here, and every terminal '
          'runs in the server.',
      workingDirectory: directory,
      agentLaunch: agentLaunch,
      restoredScrollback: restoredScrollback,
      adoptTerminal: adoptTerminal,
    );
  }
  final sessionId = terminalSessionId(
    paneId: id,
    agentSessionId: agentLaunch?.sessionId,
  );
  final terminals = ref.read(terminalsClientProvider);
  final offered = ref.read(terminalServerProfilesProvider);
  final rowId = agentLaunch?.sessionId;
  return HostTerminalInstance(
    id: id,
    title: title,
    profileId: profileId,
    access: access,
    sessionId: sessionId,
    workingDirectory: directory,
    agentLaunch: agentLaunch,
    adoptTerminal: adoptTerminal,
    restoredScrollback: restoredScrollback,
    // Known up front only for a session the server already told us of.
    shellIntegration:
        attachOnly &&
        (ref.read(dataClientProvider).terminals[sessionId]?.shellIntegration ??
            false),
    closer: () => terminals.close(sessionId),
    opener: attachOnly
        ? null
        // An agent pane is its session's: the server starts or resumes it
        // (its row, its mode, its tools — slice 5b) and the pane attaches.
        : rowId != null
        ? (columns, rows) async {
            final started = await ref
                .read(sessionsClientProvider)
                .resume(rowId, columns: columns, rows: rows);
            return (
              sessionId: started.hostSessionId,
              adopted: started.adopted,
              shellIntegration: false,
            );
          }
        : (columns, rows) async {
            final opened = await terminals.open(
              TerminalOpen(
                paneId: id,
                environmentId: agentLaunch == null
                    ? _environmentIdOf(ref, profile)
                    : null,
                workingDirectory: agentLaunch == null
                    ? workingDirectory
                    : null,
                // A profile the server does not offer — a client's default
                // from another OS — is the server's own default instead.
                profileId:
                    agentLaunch == null && offered.any((p) => p.id == profile.id)
                    ? profile.id
                    : null,
                agentLaunch: agentLaunch,
                columns: columns,
                rows: rows,
                shellIntegration: shellIntegration,
              ),
            );
            return (
              sessionId: opened.sessionId,
              adopted: opened.adopted,
              shellIntegration: opened.shellIntegration,
            );
          },
  );
}

/// The environment a shell profile opens into, when it names one: a WSL
/// profile's distribution. The server's own machine otherwise (null).
String? _environmentIdOf(Ref ref, TerminalProfile profile) {
  final distro = profile.wslDistribution;
  if (distro == null || distro.isEmpty) return null;
  for (final environment in ref.read(environmentsControllerProvider)) {
    if (environment.wslDistribution == distro) return environment.id;
  }
  return null;
}
