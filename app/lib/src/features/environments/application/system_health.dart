import 'package:flutter/foundation.dart';

import 'environment_health.dart';

/// One thing the app checked about the machine it runs on. **A check reports
/// what it observed**, so [HealthLevel.unknown] is a first-class outcome.
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
/// Machine CPU, memory and network reachability are left out on purpose.
enum SystemCheckId {
  /// The stdio bridge an agent spawns, probed by handshake.
  mcpBridge,

  /// Whether the Karmashala server serves agents' tools — read off its
  /// handshake, which needs no probe.
  agentTools,

  /// Whether a WSL distribution can start Windows programs at all.
  wslInterop,

  /// `adb`, the emulator, and whether an AVD's system image is really there.
  androidTooling,

  /// Free space where builds, emulators and worktrees land.
  diskSpace,
}

/// Everything the last check found, and when. The timestamp is part of the
/// value: a reading drawn without its age looks live however old it is.
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

  /// The reading for one check, or `null` if it has never been made. Every
  /// single-row surface goes through here, so none can invent a verdict.
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
