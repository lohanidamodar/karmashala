import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ChecksRunOutcome;
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_resolver.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_working_directory.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/visible_command_pane.dart';
import '../../verification/application/verification_providers.dart';
import 'automation_providers.dart';
import 'host_automations.dart';
import 'unattended_preflight.dart';

export 'package:karmashala_automations/check_runner.dart' show SessionChecks;

/// The `agentId` a project check's pane is opened under — namespaced, so it
/// cannot collide with a registry agent and a restored pane replays nothing.
const String kProjectCheckAgentId = 'karmashala:project-check';

/// How much of a finished check's pane is kept beside its verdict.
const int kProjectCheckRowsRecorded = 400;

/// A check's command in a visible pane of this app, waited on until its
/// process stops; a pane closed by hand reads as *not checked*, never passed.
class PaneCheckCommandRunner implements CheckCommandRunner {
  PaneCheckCommandRunner(this._ref);

  final Ref _ref;

  /// The panes a check is waiting on, from the pane opening to its process
  /// stopping.
  final Map<String, Completer<CheckExecution>> _waiting = {};

  /// A pane's process stopped: its exit code and last rows go to the check
  /// waiting on it, read now, before the instance is gone.
  void noteExit(String paneId, int? exitCode) {
    final waiting = _waiting.remove(paneId);
    if (waiting == null) return;
    waiting.complete(
      CheckExecution.ran(exitCode: exitCode, tail: _tailOf(paneId)),
    );
  }

  @override
  Future<CheckExecution> execute(
    ProjectCheck check, {
    required EnvironmentPath directory,
    required String title,
  }) async {
    final resolution = _ref
        .read(environmentResolverProvider)
        .resolveFor(directory);
    final environment = resolution.environment;
    if (environment == null) {
      return CheckExecution.refused(
        '"${check.name}" did not run: ${resolution.reason}. Whether the work '
        'still stands is unknown, not proven.',
      );
    }
    final paneId = _ref.read(visibleCommandOpenerProvider)(
      VisibleCommand(
        agentId: kProjectCheckAgentId,
        argv: check.command,
        directory: directory,
        environment: environment,
        title: title,
      ),
    );
    if (paneId == null) {
      return CheckExecution.refused(
        '"${check.name}" did not run: there was no pane to run it where '
        'anybody could see it.',
      );
    }
    final waiting = Completer<CheckExecution>();
    _waiting[paneId] = waiting;
    return waiting.future;
  }

  List<String> _tailOf(String paneId) {
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null) return const <String>[];
    return terminalTailLines(
      instance.terminal,
      lines: kProjectCheckRowsRecorded,
    );
  }
}

/// A checkout's project checks, run in this app's visible panes: where there
/// is no session host, and for a checkout the host cannot run commands in.
class AutomationCheckRunner {
  AutomationCheckRunner(this._ref) : _panes = PaneCheckCommandRunner(_ref);

  final Ref _ref;
  final PaneCheckCommandRunner _panes;

  late final ProjectCheckRunner _runner = ProjectCheckRunner(
    automations: _ref.read(automationDaoProvider),
    checks: _ref.read(projectCheckDaoProvider),
    facts: _ref.read(checkoutFactsProvider),
    commands: _panes,
    recorder: CommandCheckRecorder(
      _ref.read(verificationDaoProvider),
      _ref.read(verificationArtifactStoreProvider),
      newId: () => verificationRunId(DateTime.now()),
      now: () => _ref.read(clockProvider).nowUtc(),
      onChanged: () => _ref.read(verificationChangesProvider).bump(),
    ),
    now: () => _ref.read(clockProvider).nowUtc(),
    onChanged: () => _ref.read(automationsRevisionProvider.notifier).bump(),
    log: AppLogger.named('automations').debug,
  );

  /// Everything the last settled run set off has been written.
  Future<void> drain() => _runner.drain();

  void noteExit(String paneId, int? exitCode) =>
      _panes.noteExit(paneId, exitCode);

  /// Runs [run]'s checkout's checks and records a verdict for each. Started
  /// and not awaited.
  void start(AutomationRun run) => _runner.start(run);

  /// Runs [sessionId]'s checkout's checks in visible panes, in the directory
  /// its agent works in, as **one** verification run against it — produced
  /// by Karmashala even when the session asked. Null when there are none.
  Future<SessionChecks?> runForSession(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('No session $sessionId.');
    return _runner.runForSession(
      session,
      sessionWorkingDirectoryOf(_ref, session),
    );
  }
}

final automationCheckRunnerProvider = Provider<AutomationCheckRunner>(
  AutomationCheckRunner.new,
);

/// Whether [sessionId]'s repository has any project checks, so a surface
/// offers to run them only where there is something to run.
final sessionHasProjectChecksProvider = Provider.family<bool, String>((
  ref,
  sessionId,
) {
  final repositoryId = ref
      .watch(sessionDaoProvider)
      .getById(sessionId)
      ?.repositoryId;
  if (repositoryId == null) return false;
  return ref.watch(projectChecksProvider(repositoryId)).isNotEmpty;
});

/// The sessions whose checks are running from a surface right now, so every
/// place that offers the action shows it busy rather than starting a second
/// batch into the same worktree.
class RunningSessionChecks extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Runs [sessionId]'s checks unless they are already running: in sessions
  /// the host owns where it can, else in this app's panes.
  Future<SessionChecks?> run(String sessionId) async {
    if (state.contains(sessionId)) return null;
    state = {...state, sessionId};
    try {
      final atHost = await _atHost(sessionId);
      if (atHost != null) return atHost.value;
      return await ref
          .read(automationCheckRunnerProvider)
          .runForSession(sessionId);
    } finally {
      state = {...state}..remove(sessionId);
    }
  }

  /// The host's answer, or null when this app runs them itself.
  Future<({SessionChecks? value})?> _atHost(String sessionId) async {
    if (!ref.read(automationsAtHostProvider)) return null;
    final asked = ref.read(hostAutomationsLinkProvider).runChecks(sessionId);
    if (asked == null) return null;
    final answer = await asked;
    switch (answer.outcome) {
      case ChecksRunOutcome.elsewhere:
        return null;
      case ChecksRunOutcome.none:
        return (value: null);
      case ChecksRunOutcome.failed:
        throw StateError(
          answer.message ?? 'The session host could not run it.',
        );
      case ChecksRunOutcome.ran:
        final run = ref
            .read(verificationDaoProvider)
            .getRun(answer.verificationRunId ?? '');
        if (run == null) return (value: null);
        // The host kept the per-check lines as the run's steps.
        return (value: (checks: const <CommandCheck>[], run: run));
    }
  }
}

final runningSessionChecksProvider =
    NotifierProvider<RunningSessionChecks, Set<String>>(
      RunningSessionChecks.new,
    );
