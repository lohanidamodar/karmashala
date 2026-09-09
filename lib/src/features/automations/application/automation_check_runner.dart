import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../repositories/application/repository_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/visible_command_pane.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../../verification/application/verification_providers.dart';
import '../../verification/domain/verification_run.dart';
import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/project_check.dart';
import 'automation_providers.dart';

/// The `agentId` a project check's pane is opened under.
///
/// Namespaced like `kWorktreeSetupAgentId` and `kFlutterLoopAgentId`, and for
/// the same reason: it can never collide with a registry agent, and a restored
/// pane under it replays nothing.
const String kProjectCheckAgentId = 'karmashala:project-check';

/// How much of a finished check's pane is kept beside its verdict — the same
/// bound the Flutter loop's gates keep, for the same question.
const int kProjectCheckRowsRecorded = 400;

/// Runs a checkout's project checks after one of its automations has finished,
/// and records what each of them said.
///
/// **The Flutter loop's runner, not a second one.** A check is one command with
/// one exit code, which is exactly the shape `recordCommandCheck` exists for,
/// and it runs through `visibleCommandOpenerProvider` — the one route from "the
/// app wants to run something" to a pane, carrying the WSL distribution or the
/// SSH host of the repository it belongs to (§17). What is new here is only the
/// *sequence*: several checks, in the checkout's own order, each one waiting on
/// the last.
///
/// **Nothing polls.** A check ends when its pane's process stops, which the app
/// already announces through `PaneExitSignal`; [noteExit] is fed by
/// `AutomationRunObserver`, which is subscribed to that signal anyway, so this
/// adds no second subscription.
///
/// **A pane the user closes by hand announces nothing**, which is
/// `PaneExitSignal`'s deliberate rule. The sequence then stops where it stands
/// and the run keeps no `checks_observed_at`, so it reads as *not checked*
/// rather than as passed — the honest answer, and the same one
/// `FlutterGateObserver` gives for the same event.
class AutomationCheckRunner {
  AutomationCheckRunner(this._ref);

  final Ref _ref;

  /// The panes a check is waiting on, by pane id. An entry lives only from the
  /// moment the pane opens to the moment its process stops.
  final Map<String, Completer<_PaneOutcome>> _waiting = {};

  Future<void> _pending = Future<void>.value();

  /// Everything a settled run set off has been written.
  ///
  /// Nothing in the app awaits this: a run settling is not a call anybody made.
  /// A test reads the verdicts back and needs to know when the writes landed —
  /// the same reason `FlutterGateObserver.drain` exists beside it.
  Future<void> drain() => _pending;

  /// A pane's process stopped. Hands its exit code and its last rows to the
  /// check waiting on it, or does nothing at all — nearly every pane exit in
  /// the app belongs to something else, so this is a map lookup and silence.
  ///
  /// The rows are read **here**, in the exit's own moment, because the instance
  /// is still alive now and will not be by the time the awaiting sequence
  /// resumes.
  void noteExit(String paneId, int? exitCode) {
    final waiting = _waiting.remove(paneId);
    if (waiting == null) return;
    waiting.complete((exitCode: exitCode, tail: _tailOf(paneId)));
  }

  /// Runs [run]'s checkout's checks and records a verdict for each.
  ///
  /// Started and not awaited by the app: a checkout's test suite takes minutes
  /// and there is no caller holding on for it.
  void start(AutomationRun run) {
    // Not chained onto [_pending]: a sequence whose pane the user closed by
    // hand never finishes, and chaining would let it hold up every later run's
    // checks forever.
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
    AutomationCheckVerdict refused(String reason) => AutomationCheckVerdict(
      runId: run.id,
      ordinal: ordinal,
      checkId: check.id,
      name: check.name,
      command: check.command,
      // A check that could not be started is a verdict, and it is never a
      // pass and never a fail: nobody observed the work either way (§19).
      verdict: VerificationVerdict.inconclusive,
      reason: reason,
      checkedAt: _now,
    );

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

    final startedAt = _now;
    final String? paneId;
    try {
      paneId = _ref.read(visibleCommandOpenerProvider)(
        VisibleCommand(
          agentId: kProjectCheckAgentId,
          argv: check.command,
          directory: directory,
          environment: environment,
          title: '${check.name} · ${run.id}',
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

    final recorded = await _ref
        .read(verificationServiceProvider)
        .recordCommandCheck(
          title: '${check.name} · ${directory.path}',
          command: check.command,
          workingDirectory: directory.path,
          environmentId: environment.id,
          startedAt: startedAt,
          exitCode: outcome.exitCode,
          output: outcome.tail.join('\n'),
          // Whose work is under test: the agent's session. Nothing signs off on
          // it, so `producedBySessionId` stays null — this is the app's own
          // reading, not a session's claim about itself.
          sessionId: run.sessionId,
        );
    return AutomationCheckVerdict(
      runId: run.id,
      ordinal: ordinal,
      checkId: check.id,
      name: check.name,
      command: check.command,
      // The recorder's own verdict, so the run row and the verification record
      // cannot say two different things about one exit code.
      verdict: recorded.verdict ?? VerificationVerdict.inconclusive,
      reason: recorded.reason ?? '',
      verificationRunId: recorded.id,
      // This feature's own clock, not the recorder's: every other age on a run
      // row is taken from it, and two clocks on one row read as a disagreement.
      checkedAt: _now,
    );
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

/// What a pane left behind when its process stopped.
typedef _PaneOutcome = ({int? exitCode, List<String> tail});

final automationCheckRunnerProvider = Provider<AutomationCheckRunner>(
  AutomationCheckRunner.new,
);
