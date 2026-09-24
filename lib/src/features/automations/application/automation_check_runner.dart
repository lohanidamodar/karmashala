import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_working_directory.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/visible_command_pane.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import '../../verification/application/verification_providers.dart';
import '../../verification/application/verification_service.dart';
import '../../verification/domain/verdict_attribution.dart';
import '../../verification/domain/verification_run.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'automation_providers.dart';

/// The `agentId` a project check's pane is opened under — namespaced, so it
/// cannot collide with a registry agent and a restored pane replays nothing.
const String kProjectCheckAgentId = 'karmashala:project-check';

/// How much of a finished check's pane is kept beside its verdict — the same
/// bound the Flutter loop's gates keep, for the same question.
const int kProjectCheckRowsRecorded = 400;

/// Runs a checkout's project checks in sequence after one of its automations
/// finished; a pane closed by hand reads as *not checked*, never as passed.
class AutomationCheckRunner {
  AutomationCheckRunner(this._ref);

  final Ref _ref;

  /// The panes a check is waiting on. An entry lives only from the moment the
  /// pane opens to the moment its process stops.
  final Map<String, Completer<_PaneOutcome>> _waiting = {};

  Future<void> _pending = Future<void>.value();

  /// Everything a settled run set off has been written. Nothing in the app
  /// awaits it; a test reads the verdicts back and needs to know they landed.
  Future<void> drain() => _pending;

  /// A pane's process stopped: its exit code and last rows go to the check
  /// waiting on it. The rows are read here, before the instance is gone.
  void noteExit(String paneId, int? exitCode) {
    final waiting = _waiting.remove(paneId);
    if (waiting == null) return;
    waiting.complete((exitCode: exitCode, tail: _tailOf(paneId)));
  }

  /// Runs [run]'s checkout's checks and records a verdict for each. Started and
  /// not awaited: a test suite takes minutes and nobody is holding on.
  void start(AutomationRun run) {
    // Not chained onto `_pending`: a sequence whose pane the user closed never
    // finishes, and chaining would hold up every later run's checks forever.
    final future = _record(run).catchError((Object error) {
      AppLogger.named(
        'automations',
      ).debug('recording a project check verdict failed: $error');
    });
    _pending = future;
  }

  Future<void> _record(AutomationRun run) async {
    final dao = _ref.read(automationDaoProvider);
    final automation = dao.getById(run.automationId);
    if (automation == null) return;
    final checks = _ref
        .read(projectCheckDaoProvider)
        .forRepository(automation.repositoryId);
    if (checks.isEmpty) {
      // Observed, and there was nothing to observe with. The timestamp is what
      // makes this different from a run nobody has looked at.
      dao.noteChecksObserved(run.id, _now);
      _bump();
      return;
    }

    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(automation.repositoryId);
    final resolution = _ref
        .read(environmentResolverProvider)
        .resolveFor(repository?.path);

    var ordinal = 0;
    for (final check in checks) {
      ordinal++;
      final verdict = await _runOne(
        run: run,
        check: check,
        ordinal: ordinal,
        resolution: resolution,
        directory: repository?.path,
      );
      dao.insertRunCheck(verdict);
      _bump();
    }
    dao.noteChecksObserved(run.id, _now);
    _bump();
  }

  Future<AutomationCheckVerdict> _runOne({
    required AutomationRun run,
    required ProjectCheck check,
    required int ordinal,
    required EnvironmentResolution resolution,
    required EnvironmentPath? directory,
  }) async {
    final outcome = await _runCheck(
      check: check,
      resolution: resolution,
      directory: directory,
      paneTitle: '${check.name} · ${run.id}',
      sessionId: run.sessionId,
    );
    return AutomationCheckVerdict(
      runId: run.id,
      ordinal: ordinal,
      checkId: check.id,
      name: check.name,
      command: check.command,
      verdict: outcome.verdict,
      reason: outcome.reason,
      verificationRunId: outcome.verificationRunId,
      // This feature's own clock, not the recorder's: two clocks on one row
      // read as a disagreement.
      checkedAt: _now,
    );
  }

  /// Runs [sessionId]'s checkout's project checks, one after another in
  /// visible panes, in the directory its agent works in, and records them as
  /// **one** verification run against the session — the worst verdict of the
  /// batch. Null when the repository has none.
  ///
  /// The app's own reading of the work, never the session's claim about it:
  /// produced by [kAppVerifierId] even when the session asked for it.
  Future<SessionChecks?> runForSession(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('No session $sessionId.');
    final checks = _ref
        .read(projectCheckDaoProvider)
        .forRepository(session.repositoryId);
    if (checks.isEmpty) return null;
    final directory = sessionWorkingDirectoryOf(_ref, session);
    final resolution = _ref
        .read(environmentResolverProvider)
        .resolveFor(directory);
    final startedAt = _now;
    final ran = <CommandCheck>[];
    for (final check in checks) {
      final result = await _execute(
        check: check,
        resolution: resolution,
        directory: directory,
        paneTitle: '${check.name} · ${session.title}',
      );
      ran.add(
        CommandCheck(
          name: check.name,
          command: check.command,
          exitCode: result.exitCode,
          output: result.tail.join('\n'),
          refusal: result.refusal,
        ),
      );
    }
    final run = await _ref
        .read(verificationServiceProvider)
        .recordCommandChecks(
          title: 'Project checks · ${session.title}',
          workingDirectory: directory?.path ?? 'not recorded',
          environmentId: resolution.environment?.id ?? 'not recorded',
          startedAt: startedAt,
          checks: ran,
          sessionId: sessionId,
          // The app's own reading, never the session's claim about itself.
          producedBySessionId: kAppVerifierId,
        );
    return (checks: ran, run: run);
  }

  Future<ProjectCheckOutcome> _runCheck({
    required ProjectCheck check,
    required EnvironmentResolution resolution,
    required EnvironmentPath? directory,
    required String paneTitle,
    required String? sessionId,
  }) async {
    final startedAt = _now;
    final result = await _execute(
      check: check,
      resolution: resolution,
      directory: directory,
      paneTitle: paneTitle,
    );
    final refusal = result.refusal;
    if (refusal != null) {
      return (
        check: check,
        // A check that could not be started is never a pass and never a fail:
        // nobody observed the work either way (§19).
        verdict: VerificationVerdict.inconclusive,
        reason: refusal,
        verificationRunId: null,
      );
    }
    final recorded = await _ref
        .read(verificationServiceProvider)
        .recordCommandCheck(
          title: '${check.name} · ${directory!.path}',
          command: check.command,
          workingDirectory: directory.path,
          environmentId: resolution.environment!.id,
          startedAt: startedAt,
          exitCode: result.exitCode,
          output: result.tail.join('\n'),
          // The app's own reading, not a session's claim about itself.
          sessionId: sessionId,
          producedBySessionId: kAppVerifierId,
        );
    return (
      check: check,
      // The recorder's own verdict, so every reader of this exit code agrees.
      verdict: recorded.verdict ?? VerificationVerdict.inconclusive,
      reason: recorded.reason ?? '',
      verificationRunId: recorded.id,
    );
  }

  /// Runs one check in a visible pane and waits for it to stop, or says why
  /// it could not be run.
  Future<_Executed> _execute({
    required ProjectCheck check,
    required EnvironmentResolution resolution,
    required EnvironmentPath? directory,
    required String paneTitle,
  }) async {
    _Executed refused(String reason) =>
        (refusal: reason, exitCode: null, tail: const <String>[]);

    final commandRefusal = projectCheckCommandRefusal(check.command);
    if (commandRefusal != null) {
      return refused('"${check.name}" did not run: $commandRefusal');
    }
    final environment = resolution.environment;
    if (environment == null || directory == null) {
      return refused(
        '"${check.name}" did not run: ${resolution.reason}. Whether the work '
        'still stands is unknown, not proven.',
      );
    }

    final String? paneId;
    try {
      paneId = _ref.read(visibleCommandOpenerProvider)(
        VisibleCommand(
          agentId: kProjectCheckAgentId,
          argv: check.command,
          directory: directory,
          environment: environment,
          title: paneTitle,
        ),
      );
    } on Object catch (error) {
      return refused('"${check.name}" could not be started: $error');
    }
    if (paneId == null) {
      return refused(
        '"${check.name}" did not run: there was no pane to run it where '
        'anybody could see it.',
      );
    }

    final waiting = Completer<_PaneOutcome>();
    _waiting[paneId] = waiting;
    final outcome = await waiting.future;
    return (refusal: null, exitCode: outcome.exitCode, tail: outcome.tail);
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

  DateTime get _now => _ref.read(clockProvider).nowUtc();

  void _bump() => _ref.read(automationsRevisionProvider.notifier).bump();
}

/// One project check's verdict, and the verification record it left, if any.
typedef ProjectCheckOutcome = ({
  ProjectCheck check,
  VerificationVerdict verdict,
  String reason,
  String? verificationRunId,
});

/// One session's checks: each as it ran, and the one run that records them.
typedef SessionChecks = ({List<CommandCheck> checks, VerificationRun run});

typedef _Executed = ({String? refusal, int? exitCode, List<String> tail});

/// What a pane left behind when its process stopped.
typedef _PaneOutcome = ({int? exitCode, List<String> tail});

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

  /// Runs [sessionId]'s checks unless they are already running.
  Future<SessionChecks?> run(String sessionId) async {
    if (state.contains(sessionId)) return null;
    state = {...state, sessionId};
    try {
      return await ref
          .read(automationCheckRunnerProvider)
          .runForSession(sessionId);
    } finally {
      state = {...state}..remove(sessionId);
    }
  }
}

final runningSessionChecksProvider =
    NotifierProvider<RunningSessionChecks, Set<String>>(
      RunningSessionChecks.new,
    );
