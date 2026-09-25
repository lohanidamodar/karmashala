import 'dart:async';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../checkpoints/application/checkpoint_providers.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../terminal/application/pane_exit_signal.dart';
import 'automation_check_runner.dart';
import 'automation_providers.dart';
import 'automation_scheduler.dart';
import 'host_automations.dart';
import 'unattended_preflight.dart';

export 'package:karmashala_automations/runner.dart' show AutomationRunner;

/// The base of a run this app starts, from its checkpoint service.
class AppBaseCheckpoint implements RunBaseCheckpoint {
  const AppBaseCheckpoint(this._ref);
  final Ref _ref;

  @override
  Future<String?> capture(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  }) async {
    // `evenIfUnchanged`: undo needs a point to restore to either way.
    final base = await _ref
        .read(checkpointServiceProvider)
        .capture(
          checkout,
          sessionId: runId,
          reason: CheckpointReason.manual,
          label: label,
          evenIfUnchanged: true,
        );
    return base?.id;
  }
}

/// A run's agent, started by the app's own launcher in a pane of its own.
class AppAutomationLauncher implements AutomationSessionLauncher {
  const AppAutomationLauncher(this._ref);
  final Ref _ref;

  @override
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation,
  ) async {
    final result = await _ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository,
            installation: installation,
            title: automation.name,
            purpose: SessionPurpose.newSession,
            firstMessage: automation.prompt,
            // Null: they chose nothing and the agent's declared default stands.
            permissionOverride: automation.permissionMode,
          ),
        );
    return result.session.id;
  }
}

/// Firing an automation in this app: where there is no session host, and for
/// a checkout the host forwards because only this app can start there.
final automationRunnerProvider = Provider<AutomationRunner>(
  (ref) => AutomationRunner(
    automations: ref.watch(automationDaoProvider),
    preflight: ref.watch(unattendedPreflightProvider),
    facts: ref.watch(checkoutFactsProvider),
    checkpoints: AppBaseCheckpoint(ref),
    launcher: AppAutomationLauncher(ref),
    now: () => ref.read(clockProvider).nowUtc(),
    newId: () => ref.read(idGeneratorProvider).newId(),
    onChanged: () => ref.read(automationsRevisionProvider.notifier).bump(),
  ),
);

/// Turns "the automation's session ended" into the run's verdict for the
/// sessions this app speaks for: every one without a host, and only those off
/// this machine (SSH) where a host settles its own. Must be watched.
class AutomationRunObserver extends Notifier<int> {
  static final _log = AppLogger.named('automations');

  int _revision = 0;
  bool _disposed = false;

  @override
  int build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.status,
    });

    final sessions = ref.read(sessionDaoProvider);
    final atHost = ref.watch(automationsAtHostProvider);
    final followsHost = ref.watch(sessionFollowsHostFactsProvider);
    final onThisMachine = ref.watch(sessionRunsOnThisMachineProvider);
    // What the store records, this app settles — all of it without a host,
    // only what is off this machine where the host settles its own.
    final bool Function(Session)? owns = atHost
        ? (session) => !onThisMachine(session)
        : null;
    // What a pane or a live status says only counts for a row no host speaks
    // for: a pane exit there may be a host restart.
    bool oursById(String sessionId) {
      final row = sessions.getById(sessionId);
      if (row == null) return true;
      return !followsHost(row) && (owns?.call(row) ?? true);
    }

    final settler = AutomationRunSettler(
      automations: ref.read(automationDaoProvider),
      sessionOf: sessions.getById,
      runChecks: ref.read(automationCheckRunnerProvider).start,
      drain: (repositoryId) =>
          ref.read(automationSchedulerProvider.notifier).drain(repositoryId),
      now: () => ref.read(clockProvider).nowUtc(),
      onChanged: () {
        _revision++;
        ref.read(automationsRevisionProvider.notifier).bump();
      },
      log: _log.warning,
    );

    // The clean finish of a session without host facts.
    ref.listen(paneExitProvider, (_, exit) {
      if (exit == null) return;
      // A project check's pane is not a session's; its rows are read now.
      ref
          .read(automationCheckRunnerProvider)
          .noteExit(exit.paneId, exit.exitCode);
      final sessionId = exit.sessionId;
      if (sessionId == null || !oursById(sessionId)) return;
      final ending = endingOfPaneExit(exit.exitCode);
      if (ending != null) settler.settleSession(sessionId, ending);
    });

    // The only crash report for a session without host facts.
    for (final run in ref.read(automationDaoProvider).liveRuns()) {
      if (run.state != AutomationRunState.running) continue;
      final sessionId = run.sessionId;
      if (sessionId == null) continue;
      if (sessions.getById(sessionId)?.status != SessionStatus.running) {
        continue;
      }
      ref.listen(agentSessionStatusProvider(sessionId), (previous, next) {
        final to = next.value?.status;
        if (to == null || !oursById(sessionId)) return;
        final transition = endingOfTransition(
          from: previous?.value?.status,
          to: to,
        );
        if (transition != null) settler.settleSession(sessionId, transition);
      });
    }

    // The durable half, deferred: it writes.
    unawaited(
      Future<void>.microtask(() {
        if (!_disposed) settler.sweep(owns: owns);
      }),
    );
    return _revision;
  }
}

final automationRunObserverProvider =
    NotifierProvider<AutomationRunObserver, int>(AutomationRunObserver.new);
