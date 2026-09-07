import 'agent_installation.dart';

/// One installation whose executable turned out to be somewhere else.
///
/// A move keeps the row and its id — see `AgentInstallationDao.updatePath` —
/// so this is a *change* to report, not an add and a remove.
class AgentPathChange {
  const AgentPathChange({
    required this.displayName,
    required this.from,
    required this.to,
  });

  final String displayName;
  final String from;
  final String to;

  @override
  String toString() => '$displayName: $from → $to';
}

/// One installation whose recorded version no longer matches what the CLI says.
class AgentVersionChange {
  const AgentVersionChange({
    required this.displayName,
    required this.from,
    required this.to,
  });

  final String displayName;
  final String? from;
  final String? to;

  @override
  String toString() => '$displayName ${from ?? '?'} → ${to ?? '?'}';
}

/// What one re-detection established about one execution environment.
class EnvironmentScanReport {
  const EnvironmentScanReport({
    required this.environmentId,
    required this.environmentName,
    required this.reachable,
    this.error,
    this.found = const [],
    this.missing = const [],
    this.added = const [],
    this.removed = const [],
    this.retained = const [],
    this.updated = const [],
    this.movedPaths = const [],
    this.unreachablePaths = const [],
    this.pinnedPaths = const [],
  });

  /// The environment could not be asked. Nothing below is a claim about what
  /// is installed there — only that we could not look.
  const EnvironmentScanReport.unreachable({
    required this.environmentId,
    required this.environmentName,
    required this.error,
  }) : reachable = false,
       found = const [],
       missing = const [],
       added = const [],
       removed = const [],
       retained = const [],
       updated = const [],
       movedPaths = const [],
       unreachablePaths = const [],
       pinnedPaths = const [];

  final String environmentId;
  final String environmentName;
  final bool reachable;
  final String? error;

  /// Installations present here after the scan.
  final List<AgentInstallation> found;

  /// Display names of agents that were probed for and are not installed.
  final List<String> missing;

  final List<AgentInstallation> added;
  final List<AgentInstallation> removed;

  /// Uninstalled here, but kept on record because sessions still point at them.
  ///
  /// Neither found nor removed, and reported as neither: counting these among
  /// [found] would claim an agent is installed when the scan just proved it is
  /// not, and dropping them silently would leave the environment listing a row
  /// the summary never mentions.
  final List<AgentInstallation> retained;

  final List<AgentVersionChange> updated;

  /// Installations that were found at a new path and followed to it.
  final List<AgentPathChange> movedPaths;

  /// Installations kept because the route to their executable could not be
  /// established — not because it was proved gone.
  ///
  /// Its own list, and deliberately counted among neither [found] nor
  /// [missing]. A junction chain Windows will not traverse answers `where` and
  /// `existsSync` exactly like an uninstalled CLI, so calling this "not
  /// installed" would be the §19 lie — and calling it "installed" would be the
  /// same lie facing the other way. What the user needs is that the file is
  /// somewhere we cannot reach, because "install it" and "fix the route" are
  /// opposite instructions.
  final List<AgentInstallation> unreachablePaths;

  /// Installations the sweep left alone because a human chose their path and it
  /// still works.
  final List<AgentInstallation> pinnedPaths;
}

/// The truthful account of a whole re-detection run.
///
/// It carries the misses and the unreachable environments as first-class
/// results, not just the hits, because "the scan succeeded" is not an answer to
/// "did you find my agent" — and an operation in this app that reported success
/// while having done nothing is exactly the failure this feature exists after.
class AgentDiscoveryReport {
  const AgentDiscoveryReport(this.environments);

  const AgentDiscoveryReport.empty() : environments = const [];

  final List<EnvironmentScanReport> environments;

  /// Every installation on record after the run, across environments.
  List<AgentInstallation> get installations => [
    for (final environment in environments) ...environment.found,
  ];

  int get foundCount => installations.length;
  int get addedCount => _sum((e) => e.added.length);
  int get removedCount => _sum((e) => e.removed.length);
  int get retainedCount => _sum((e) => e.retained.length);
  int get updatedCount => _sum((e) => e.updated.length);
  int get movedCount => _sum((e) => e.movedPaths.length);
  int get unreachableCount => _sum((e) => e.unreachablePaths.length);
  int get pinnedCount => _sum((e) => e.pinnedPaths.length);

  List<EnvironmentScanReport> get unreachable => [
    for (final environment in environments)
      if (!environment.reachable) environment,
  ];

  int _sum(int Function(EnvironmentScanReport) of) =>
      environments.fold(0, (total, e) => total + of(e));

  /// One sentence a person can act on, naming what was *not* found as plainly
  /// as what was.
  String get summary {
    final scanned = environments.where((e) => e.reachable).toList();
    if (scanned.isEmpty) {
      return environments.isEmpty
          ? 'No environments to scan.'
          : 'Could not reach ${_names(unreachable)} — nothing was re-detected.';
    }

    final parts = <String>[
      foundCount == 0
          ? 'No agents found in ${_count(scanned.length, 'environment')}.'
          : 'Found ${_count(foundCount, 'agent')} in '
                '${_count(scanned.length, 'environment')}.',
      if (addedCount > 0) '$addedCount new.',
      if (movedCount > 0) '${_count(movedCount, 'path')} repaired.',
      if (updatedCount > 0) '${_count(updatedCount, 'version')} changed.',
      if (removedCount > 0) '$removedCount no longer installed.',
      if (retainedCount > 0)
        '$retainedCount gone but kept for sessions that used it.',
      if (pinnedCount > 0) '$pinnedCount left at the path you set.',
      if (unreachableCount > 0)
        '$unreachableCount installed somewhere that cannot be reached.',
    ];

    final missing = <String>[
      for (final environment in scanned)
        for (final name in environment.missing)
          '$name on ${environment.environmentName}',
    ];
    if (missing.isNotEmpty) parts.add('Not installed: ${missing.join(', ')}.');
    if (unreachable.isNotEmpty) {
      parts.add('Could not reach ${_names(unreachable)}.');
    }
    return parts.join(' ');
  }

  static String _names(List<EnvironmentScanReport> of) =>
      of.map((e) => e.environmentName).join(', ');

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}
