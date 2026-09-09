import '../../util/path_probe.dart';
import './agent_discovery_report.dart';
import './agent_installation.dart';

/// One stored installation's executable, as the filesystem answered.
class AgentPathReading {
  const AgentPathReading({
    required this.installation,
    required this.displayName,
    required this.reading,
  });

  final AgentInstallation installation;

  /// The agent's display name, resolved through the registry so the report can
  /// be rendered without one.
  final String displayName;

  final ExecutableReading reading;

  ExecutableReachability get reachability => reading.reachability;
  bool get isUsable => reading.isUsable;

  /// Whether this row needs a repair: observed to be something other than
  /// usable. An [ExecutableReachability.unchecked] row needs nothing, because
  /// nothing was observed about it.
  bool get isBroken =>
      reachability == ExecutableReachability.missing ||
      reachability == ExecutableReachability.unreachable;
}

/// What a check of the stored agent executables established, and what a repair
/// did about it.
///
/// Carries [checkedAt] because §19 requires a reading to show its age, and
/// carries [scan] rather than folding it away because a repair that had to
/// re-probe has an account of its own worth showing.
class AgentPathRepairReport {
  const AgentPathRepairReport({
    required this.checkedAt,
    this.broken = const [],
    this.repaired = const [],
    this.unresolved = const [],
    this.scan,
  });

  /// Nothing has been checked yet this run. Distinct from a check that found
  /// nothing wrong, which is a report with an empty [broken].
  const AgentPathRepairReport.unchecked()
    : checkedAt = null,
      broken = const [],
      repaired = const [],
      unresolved = const [],
      scan = null;

  /// When the check ran, or null if it has not.
  final DateTime? checkedAt;

  /// Rows whose executable was not usable when the check ran.
  final List<AgentPathReading> broken;

  /// Rows that now point at a usable executable.
  final List<AgentPathReading> repaired;

  /// Rows still not usable after the repair.
  ///
  /// **Kept, never deleted.** A repair that finds nothing has established
  /// nothing, and replacing a broken row with no row at all would take the
  /// agent out of Settings entirely — which is worse than a wrong path,
  /// because a wrong path can be seen and corrected.
  final List<AgentPathReading> unresolved;

  /// The sweep the repair ran, when it needed one.
  final AgentDiscoveryReport? scan;

  bool get hasChecked => checkedAt != null;

  /// Whether the check found every stored executable where it expected it.
  bool get isClean => hasChecked && broken.isEmpty;

  /// The rows that are still unreachable rather than absent — the ones whose
  /// executable is somewhere the app cannot get to, which needs a different
  /// remedy from installing the CLI.
  List<AgentPathReading> get stillUnreachable => [
    for (final reading in unresolved)
      if (reading.reachability == ExecutableReachability.unreachable) reading,
  ];

  /// One sentence a person can act on.
  String get summary {
    if (!hasChecked) return 'The stored agent paths have not been checked yet.';
    if (broken.isEmpty) {
      return 'Every stored agent path is where it should be.';
    }
    final parts = <String>[
      '${_count(broken.length, 'stored agent path')} did not open.',
      if (repaired.isNotEmpty) '${repaired.length} repaired.',
      for (final reading in unresolved)
        switch (reading.reachability) {
          // Not "not installed": the route to it could not be established, so
          // the file may be perfectly fine and unreachable.
          ExecutableReachability.unreachable =>
            '${reading.displayName} is installed at '
                '${reading.installation.executable.path} but cannot be '
                'reached — its path leads through a link this machine will '
                'not follow.',
          _ =>
            '${reading.displayName} is not at '
                '${reading.installation.executable.path} any more and was not '
                'found anywhere else; its record was kept so you can set the '
                'path yourself.',
        },
    ];
    return parts.join(' ');
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}
