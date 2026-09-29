import 'dart:async';

import 'package:agent_cli/process.dart' show EnvironmentKind;

import 'package:flutter/foundation.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/metadata_keys.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_health.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/application/system_health_service.dart';
import '../../projects/application/projects_controller.dart';
import '../../remote/data/paired_devices_data.dart';
import '../../sessions/application/session_providers.dart';

/// The quick start's steps that count. Each is done only when the thing
/// exists — a project, a session, a reading, a paired phone — never when the
/// chooser for it was opened.
enum QuickStartStep {
  machine('Check this machine'),
  project('Add a project'),
  session('Start a session'),
  phone('Pair a phone');

  const QuickStartStep(this.label);

  final String label;
}

/// Whether the quick start is offered. Absent means an install that predates
/// it, which is not shown one unasked.
enum QuickStartVisibility { unoffered, open, dismissed }

@immutable
class QuickStartState {
  const QuickStartState({required this.visibility, required this.done});

  final QuickStartVisibility visibility;

  /// Recorded and live together: a project removed after it was added still
  /// taught what it was there to teach.
  final Set<QuickStartStep> done;

  bool get shown => visibility == QuickStartVisibility.open;
  bool isDone(QuickStartStep step) => done.contains(step);
  bool get allDone => done.length == QuickStartStep.values.length;
}

/// The quick start's progress, kept with this desktop's server preferences
/// (under `KARMASHALA_DATA_DIR` for a probe) — not per project.
class QuickStartController extends Notifier<QuickStartState> {
  @override
  QuickStartState build() {
    final preferences = ref.watch(appPreferencesProvider);
    final sub = preferences.changes.listen((_) => _reread());
    ref.onDispose(sub.cancel);

    final sessions = ref.watch(sessionsDataProvider);
    final sessionSub = sessions.changes.listen((_) => _observe());
    ref.onDispose(sessionSub.cancel);
    ref.listen(projectsControllerProvider, (_, _) => _observe());
    ref.listen(pairedDevicesProvider, (_, _) => _observe());
    ref.listen(
      systemHealthProvider.select((r) => r.hasRun),
      (_, _) => _observe(),
    );
    final initial = _read();
    // After the build: a write here would change a provider mid-build.
    Future.microtask(() {
      if (ref.mounted) _observe();
    });
    return initial;
  }

  QuickStartState _read() {
    final preferences = ref.read(appPreferencesProvider);
    final visibility = switch (preferences.read(MetadataKeys.quickStart)) {
      'open' => QuickStartVisibility.open,
      'dismissed' => QuickStartVisibility.dismissed,
      _ => QuickStartVisibility.unoffered,
    };
    final recorded = {
      for (final name
          in (preferences.read(MetadataKeys.quickStartDone) ?? '').split(','))
        ?QuickStartStep.values.where((s) => s.name == name).firstOrNull,
    };
    return QuickStartState(
      visibility: visibility,
      done: {...recorded, ..._live()},
    );
  }

  void _reread() {
    final next = _read();
    if (next.visibility != state.visibility ||
        !setEquals(next.done, state.done)) {
      state = next;
    }
  }

  /// What is true now, measured from the app's own state.
  Set<QuickStartStep> _live() => {
    if (ref.read(systemHealthProvider).hasRun) QuickStartStep.machine,
    if (ref.read(projectsControllerProvider).isNotEmpty) QuickStartStep.project,
    if (ref.read(sessionsDataProvider).getAll().isNotEmpty)
      QuickStartStep.session,
    if (ref.read(pairedDevicesProvider).any((d) => !d.revoked))
      QuickStartStep.phone,
  };

  /// Records what has become true while the quick start is offered, so the
  /// progress outlives the project or session that earned it.
  void _observe() {
    final current = _read();
    if (current.visibility != QuickStartVisibility.open) {
      _reread();
      return;
    }
    final preferences = ref.read(appPreferencesProvider);
    final recorded = preferences.read(MetadataKeys.quickStartDone) ?? '';
    final names = [
      for (final step in QuickStartStep.values)
        if (current.done.contains(step)) step.name,
    ].join(',');
    if (names != recorded) {
      preferences.write(MetadataKeys.quickStartDone, names);
    }
    _reread();
  }

  /// Shows the quick start again — from the command palette.
  void reopen() {
    ref.read(appPreferencesProvider).write(MetadataKeys.quickStart, 'open');
    _observe();
  }

  /// "Don't show again": until [reopen].
  void dismiss() {
    ref
        .read(appPreferencesProvider)
        .write(MetadataKeys.quickStart, 'dismissed');
    _reread();
  }

  /// The first run: the quick start opens beside the terminal and the machine
  /// is checked once. Probes only — nothing is installed from here.
  void beginFirstRun() {
    reopen();
    unawaited(ref.read(systemHealthProvider.notifier).refresh());
  }
}

final quickStartProvider =
    NotifierProvider<QuickStartController, QuickStartState>(
      QuickStartController.new,
    );

/// Whether the quick start's body is folded to its header. The window's, not
/// the desktop's: it comes back open next launch.
class QuickStartFoldController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final quickStartFoldedProvider =
    NotifierProvider<QuickStartFoldController, bool>(
      QuickStartFoldController.new,
    );

// --- Preflight --------------------------------------------------------------

/// One local environment as the preflight reads it.
@immutable
class PreflightEnvironment {
  const PreflightEnvironment({
    required this.name,
    required this.kind,
    required this.agents,
    required this.git,
    this.gitVersion,
  });

  final String name;
  final EnvironmentKind kind;

  bool get isWsl => kind == EnvironmentKind.wsl;

  /// "Claude Code 2.1.283", in registry order.
  final List<String> agents;

  /// [HealthLevel.unknown] until a reading exists.
  final HealthLevel git;
  final String? gitVersion;
}

/// Something the preflight did not find, and how a person installs it
/// themselves. Nothing is installed from the app.
@immutable
class PreflightGap {
  const PreflightGap({
    required this.title,
    required this.summary,
    this.command,
    this.optional = false,
  });

  final String title;
  final String summary;

  /// A line to copy and run, when there is a well-known one.
  final String? command;

  /// Not needed to start: WSL, a second agent.
  final bool optional;
}

@immutable
class Preflight {
  const Preflight({
    required this.environments,
    required this.gaps,
    required this.checking,
    required this.findingAgents,
    required this.checked,
    required this.otherIssues,
    required this.foundAgents,
  });

  final List<PreflightEnvironment> environments;

  /// Every agent found in any environment (SSH boxes included), by name.
  final List<String> foundAgents;
  final List<PreflightGap> gaps;

  /// The system check is running — it cannot measure its own progress, so the
  /// view names what it is doing instead of a percentage.
  final bool checking;

  /// The first-run agent search has not finished (or failed and retries next
  /// launch); no agent found yet is then not a finding.
  final bool findingAgents;

  /// A reading exists.
  final bool checked;

  /// System checks other than the environments' that are not healthy — the
  /// MCP bridge, WSL interop, disk — for the details dialog to explain.
  final int otherIssues;

  /// What the running check probes, in the words the user can check.
  static const checkingWhat =
      'Running git --version in each environment, then the MCP bridge, '
      'WSL interop, Android tooling and disk space. Read-only.';
}

/// The review a first run shows: which agent CLIs each local environment has,
/// whether git answers there, whether WSL is present — read from the agent
/// discovery and the system health reading the app already keeps.
final preflightProvider = Provider<Preflight>((ref) {
  final registry = ref.watch(agentRegistryProvider);
  final installs = ref.watch(agentInstallationsControllerProvider);
  final environments = ref
      .watch(environmentsControllerProvider)
      .where((e) => e.kind != EnvironmentKind.ssh)
      .toList();
  final report = ref.watch(systemHealthProvider);
  final preferences = ref.watch(appPreferencesProvider);

  HealthEnvironmentReading? gitOf(String id) {
    for (final health in report.environments) {
      if (health.environment.id == id) {
        return (health.level, health.gitVersion);
      }
    }
    return null;
  }

  final rows = [
    for (final environment in environments)
      () {
        final here = [
          for (final descriptor in registry.descriptors)
            for (final install in installs)
              if (install.agentId == descriptor.id &&
                  install.environmentId == environment.id)
                install.version == null
                    ? descriptor.displayName
                    : '${descriptor.displayName} ${install.version}',
        ];
        final git = gitOf(environment.id);
        return PreflightEnvironment(
          name: environment.name,
          kind: environment.kind,
          agents: here,
          // A reachable environment whose git ran reports its version; one
          // that failed is `failed`. "No agents" is not a git failure.
          git: git == null
              ? HealthLevel.unknown
              : (git.$2 != null ? HealthLevel.healthy : HealthLevel.failed),
          gitVersion: git?.$2,
        );
      }(),
  ];

  final findingAgents =
      preferences.read(MetadataKeys.agentsDiscoveredAt) == null &&
      installs.isEmpty;
  final hostIsWindows = environments.any(
    (e) => e.kind == EnvironmentKind.windowsNative,
  );
  final gaps = <PreflightGap>[
    for (final row in rows)
      if (row.git == HealthLevel.failed)
        PreflightGap(
          title: 'git in ${row.name}',
          summary: row.kind == EnvironmentKind.windowsNative
              ? 'git did not answer. Sessions, worktrees and Changes need it.'
              : 'git did not answer. Install it with the package manager '
                    'there; sessions, worktrees and Changes need it.',
          command: row.kind == EnvironmentKind.windowsNative
              ? 'winget install --id Git.Git -e'
              : null,
        ),
    if (!findingAgents)
      for (final descriptor in registry.descriptors)
        if (!installs.any((i) => i.agentId == descriptor.id))
          PreflightGap(
            title: descriptor.displayName,
            summary: installs.isEmpty
                ? 'Not found in any environment. A session needs at least one '
                      'agent CLI.'
                : 'Not found in any environment.',
            command:
                switch (descriptor.launch.selfUpdate.latestVersion.npmPackage) {
                  final package? => 'npm install -g $package',
                  null => null,
                },
            optional: installs.isNotEmpty,
          ),
    if (hostIsWindows &&
        !environments.any((e) => e.kind == EnvironmentKind.wsl))
      const PreflightGap(
        title: 'WSL',
        summary:
            'No WSL distribution found. Optional: agents run natively too.',
        command: 'wsl --install',
        optional: true,
      ),
  ];

  return Preflight(
    environments: rows,
    gaps: gaps,
    checking: report.running,
    findingAgents: findingAgents,
    checked: report.hasRun,
    foundAgents: [
      for (final descriptor in registry.descriptors)
        if (installs.any((i) => i.agentId == descriptor.id))
          descriptor.displayName,
    ],
    otherIssues: report.checks
        .where(
          (c) =>
              c.level == HealthLevel.warning || c.level == HealthLevel.failed,
        )
        .length,
  );
});

typedef HealthEnvironmentReading = (HealthLevel, String?);
