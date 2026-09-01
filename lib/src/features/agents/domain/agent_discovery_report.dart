import 'agent_installation.dart';

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
    this.updated = const [],
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
       updated = const [];

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
  final List<AgentVersionChange> updated;
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
  int get updatedCount => _sum((e) => e.updated.length);

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
      if (updatedCount > 0)
        '${_count(updatedCount, 'version')} changed.',
      if (removedCount > 0) '$removedCount no longer installed.',
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

  static String _count(int n, String noun) =>
      '$n $noun${n == 1 ? '' : 's'}';
}
