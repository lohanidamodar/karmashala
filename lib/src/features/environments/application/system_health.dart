import 'package:flutter/foundation.dart';

import 'environment_health.dart';

/// One thing the app checked about the machine it is running on.
///
/// **A check reports what it observed, never what it assumes.** The panel this
/// feeds used to say "Tools available — the MCP bridge is installed" because a
/// file was on disk; on 2026-09-03 that sentence was on screen for over an hour
/// while every Karmashala tool in an agent session was gone, because WSL's
/// interop handler had disappeared and the file, though perfectly runnable,
/// could not be spawned by the process that needed it. A confident false
/// statement is worse than an admission of ignorance — the same rule
/// `AgentStatusReport.evidence` and `DeviceCapability` are written to.
///
/// So [HealthLevel.unknown] is a first-class outcome here, not a failure to
/// model one: "we could not tell" is drawn in [SemanticColors.neutral] and says
/// what stopped it.
@immutable
class SystemCheck {
  const SystemCheck({
    required this.id,
    required this.title,
    required this.level,
    required this.summary,
    this.detail,
    this.remedy,
    this.remedyCommand,
    this.took,
  });

  /// A check the app deliberately did not run, and why.
  const SystemCheck.notChecked({
    required this.id,
    required this.title,
    required String reason,
  }) : level = HealthLevel.unknown,
       summary = reason,
       detail = null,
       remedy = null,
       remedyCommand = null,
       took = null;

  final SystemCheckId id;

  /// What was checked, as a row heading.
  final String title;

  final HealthLevel level;

  /// The verdict, in one sentence.
  final String summary;

  /// The evidence behind [summary] — an error as the OS reported it, a version
  /// string, a measurement. Shown beneath the verdict, not instead of it.
  final String? detail;

  /// What the user can do about it. A verdict nobody can act on is half a
  /// feature.
  final String? remedy;

  /// A command that carries out [remedy], offered to copy.
  final String? remedyCommand;

  /// How long the check took. Probes spawn processes; this is what says so.
  final Duration? took;

  SystemCheck copyWith({String? title, Duration? took}) => SystemCheck(
    id: id,
    title: title ?? this.title,
    level: level,
    summary: summary,
    detail: detail,
    remedy: remedy,
    remedyCommand: remedyCommand,
    took: took ?? this.took,
  );
}

/// The checks this app knows how to run, in the order they are shown.
///
/// **What is deliberately absent is as much a decision as what is here**, and
/// the exclusions are recorded in `docs/` rather than left to be rediscovered:
///
/// * **A client's MCP connection.** Claude Code binds its servers when it
///   starts and owns those processes. This app can spawn *its own* bridge and
///   watch its own endpoint; it cannot see whether a CLI's server list is
///   healthy, and a row claiming to would be the same lie in a new place.
/// * **Network reachability.** Nothing here needs the internet, and a probe of
///   somebody else's host reports their weather, not this machine's.
/// * **Git and SSH per environment.** Already measured, per environment, by
///   [EnvironmentHealthService]; a second row that could disagree with the
///   first is exactly the failure this panel exists to avoid.
/// * **CPU and memory.** No incident has turned on either, and a number with no
///   threshold beside it is noise that trains the eye to skip the panel.
enum SystemCheckId {
  /// The stdio bridge an agent spawns, probed by handshake.
  mcpBridge,

  /// Whether the app is willing to answer that bridge — [ControlServerStatus],
  /// which is already observed and needs no probe.
  controlServer,

  /// Whether a WSL distribution can start Windows programs at all.
  wslInterop,

  /// `adb`, the emulator, and whether an AVD's system image is really there.
  androidTooling,

  /// Free space where builds, emulators and worktrees land.
  diskSpace,
}

/// Everything the last check found, and when it found it.
///
/// The timestamp is part of the value rather than something the UI stamps on
/// render, for the reason `AgentStatusReport.evidenceAt` exists: a reading
/// drawn without its age looks live no matter how old it is.
@immutable
class SystemHealthReport {
  const SystemHealthReport({
    required this.checks,
    required this.environments,
    required this.checkedAt,
    this.running = false,
  });

  /// Nothing has been checked. **Not** a healthy state and not an unhealthy
  /// one — the honest starting point, which the UI draws as "not checked yet".
  static const SystemHealthReport notChecked = SystemHealthReport(
    checks: [],
    environments: [],
    checkedAt: null,
  );

  final List<SystemCheck> checks;

  /// Per-environment reachability, unchanged: can we run git there, and which
  /// agents were found.
  final List<EnvironmentHealth> environments;

  /// When the checks below ran, or `null` if they never have.
  final DateTime? checkedAt;

  /// A check is in flight. Kept separate from `checkedAt == null` so a refresh
  /// shows the previous reading with a spinner rather than blanking it.
  final bool running;

  bool get hasRun => checkedAt != null;

  /// The reading for one check, or `null` if it has never been made.
  ///
  /// Null is the honest answer for "we have not looked", and every surface that
  /// reads a single row goes through here so that none of them can invent a
  /// verdict out of an empty list.
  SystemCheck? checkFor(SystemCheckId id) {
    for (final check in checks) {
      if (check.id == id) return check;
    }
    return null;
  }

  /// The worst level observed, or [HealthLevel.unknown] before anything ran.
  HealthLevel get worst {
    if (!hasRun) return HealthLevel.unknown;
    var worst = HealthLevel.healthy;
    for (final level in [
      ...checks.map((c) => c.level),
      ...environments.map((e) => e.level),
    ]) {
      if (level.index > worst.index) worst = level;
    }
    return worst;
  }

  SystemHealthReport copyWith({bool? running}) => SystemHealthReport(
    checks: checks,
    environments: environments,
    checkedAt: checkedAt,
    running: running ?? this.running,
  );
}
