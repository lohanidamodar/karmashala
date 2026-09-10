part of 'session_launcher.dart';

/// Can this agent still be started? A stored path is state and whether it
/// resolves is a measurement, and the boot sweep's answer is stale the moment
/// a CLI self-updates mid-session (CLAUDE.md §20).
extension SessionExecutableGuard on SessionLauncher {
  /// [installation] with an executable that opens, repairing the row when the
  /// binary can still be reached. Throws [SessionLaunchRefused] when it cannot.
  ///
  /// One `existsSync` and no process at all when nothing is wrong. A WSL or SSH
  /// row is never judged from here: a stat of ours is not evidence about their
  /// disk, and asking properly costs a spawn on every launch.
  Future<AgentInstallation> usableInstallation(
    AgentInstallation installation,
  ) async {
    final reading = _localReading(installation);
    if (reading == null || reading.isUsable) return installation;

    // The sweep Settings runs, not a second repair beside it: both routes have
    // to agree on what a broken row is and on what fixing one means.
    await _ref
        .read(agentInstallationsControllerProvider.notifier)
        .repairBrokenPaths();

    final repaired = _ref
        .read(agentInstallationDaoProvider)
        .getById(installation.id);
    final after = repaired == null ? null : _localReading(repaired);
    if (repaired != null && (after == null || after.isUsable)) {
      _log.info(
        'Repaired ${repaired.agentId} before launching it: '
        '${installation.executable.path} -> ${repaired.executable.path}',
      );
      return repaired;
    }

    throw SessionLaunchRefused(
      agentExecutableRefusal(
        agentName: agentDisplayName(installation.agentId),
        path: (repaired ?? installation).executable.path,
        reachability: after?.reachability ?? reading.reachability,
      ),
    );
  }

  /// What this host can say about [installation]'s executable, or null when it
  /// is not ours to judge — a WSL or SSH path is spelled for its own disk.
  ExecutableReading? _localReading(AgentInstallation installation) {
    final environment = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(installation.environmentId);
    if (environment == null || !isLocalHost(environment.kind)) return null;
    return readExecutable(
      installation.executable.path,
      _ref.read(agentCliPathProbeProvider),
      context: usesWindowsPaths(environment.kind) ? p.windows : p.posix,
    );
  }
}
