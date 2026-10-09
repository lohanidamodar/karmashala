import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/check_runner.dart' show SessionChecks;
import 'package:karmashala_automations/checks.dart' show ProjectCheck;
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart' show splitCommandLine;
import 'package:karmashala_session/lineage.dart' show SessionLink;
import 'package:karmashala_session/session.dart' show sessionBranchName;

import '../status/child_turn_wait.dart';

/// What answers the pipeline requests a client asks of the server.
abstract interface class PipelinesWork {
  Future<Object?> handle(PipelinesRequest<Object?> request);
}

/// **Where a stage launch waits its turn.** The server's concurrency gate
/// (round 79) admits it; until that is wired, [OpenStageLaunchGate] lets
/// every launch through at once.
abstract interface class StageLaunchGate {
  Future<T> admit<T>(StagePriority priority, Future<T> Function() launch);
}

class OpenStageLaunchGate implements StageLaunchGate {
  const OpenStageLaunchGate();

  @override
  Future<T> admit<T>(StagePriority priority, Future<T> Function() launch) =>
      launch();
}

/// Starts each stage as a real session through the server's one launch path,
/// behind [gate], and opens its tab beside its parent's.
class ServerStageLauncher implements StageLauncher {
  ServerStageLauncher({
    required this.start,
    required this.defaultInstallation,
    required this.gate,
    this.opened,
  });

  final Future<SessionStarted> Function(SessionStartSpec spec) start;

  /// The installation a stage that names none starts: the checkout's default.
  final String Function(String repositoryId) defaultInstallation;
  final StageLaunchGate gate;
  final void Function(SessionStarted started, StageLaunch launch)? opened;

  @override
  Future<StageLaunched> launch(StageLaunch launch) => gate.admit(
    launch.priority,
    () async {
      final previous = launch.worktreePath;
      final started = await start(
        SessionStartSpec(
          repositoryId: launch.repositoryId,
          installationId:
              launch.installationId ?? defaultInstallation(launch.repositoryId),
          title: launch.title,
          titleTyped: true,
          prompt: launch.prompt,
          systemPrompt: launch.systemPrompt,
          worktree: launch.workspace == PipelineWorkspace.newWorktree,
          existingWorktree:
              launch.workspace == PipelineWorkspace.previousWorktree &&
                  previous != null
              ? EnvironmentPath(
                  environmentId: launch.environmentId ?? '',
                  path: previous,
                )
              : null,
          permissionMode: launch.permissionMode,
          modelId: launch.modelId,
          parentSessionId: launch.parentSessionId,
          parentLink: launch.parentSessionId == null ? null : SessionLink.spawn,
        ),
      );
      opened?.call(started, launch);
      final session = started.session;
      final worktree = session.worktreeRemoved ? null : session.worktree;
      return StageLaunched(
        sessionId: session.id,
        worktreePath: worktree?.path,
        environmentId: worktree?.environmentId,
        branch: launch.workspace == PipelineWorkspace.newWorktree
            ? sessionBranchName(session.id)
            : null,
      );
    },
  );
}

/// How long one wait on a stage's turn lasts before it is asked again.
const Duration kStageWaitSlice = Duration(minutes: 10);

/// Follows a stage session's turn through [turns], however long it takes: a
/// stage blocked on a question waits for the person to answer it.
class ServerStageWatcher implements StageWatcher {
  ServerStageWatcher({
    required this.turns,
    required this.end,
    this.pause = const Duration(seconds: 5),
  });

  final ChildTurnWait turns;
  final Future<void> Function(String sessionId) end;
  final Duration pause;

  @override
  Future<StageTurn> turnOf(String sessionId, {required DateTime since}) async {
    while (true) {
      final outcome = await turns.firstTurn(
        sessionId,
        bound: kStageWaitSlice,
        since: since,
      );
      switch (outcome.state) {
        case ChildTurnState.done:
          final answer = await turns.answerOf(sessionId, since: since);
          return StageTurn.done(answer?.text ?? '');
        case ChildTurnState.failed:
          return const StageTurn.failed('The agent stopped with an error.');
        case ChildTurnState.ended:
          final answer = await turns.answerOf(sessionId, since: since);
          // A session that answered and then ended still handed its work on.
          return answer == null || answer.text.trim().isEmpty
              ? const StageTurn.failed('The session ended before it answered.')
              : StageTurn.done(answer.text);
        case ChildTurnState.blocked:
          await Future<void>.delayed(pause);
        case ChildTurnState.running:
          break;
      }
    }
  }

  @override
  Future<void> stop(String sessionId) => end(sessionId);
}

/// What a stage left behind: its artifacts from the library, and its check
/// gate run as one verification run by the automations' check runner.
class ServerStageEvidence implements StageEvidence {
  ServerStageEvidence({
    required this.listArtifacts,
    required this.contentOf,
    required this.runChecks,
    required this.now,
  });

  final List<PipelineArtifactRef> Function(String sessionId) listArtifacts;
  final Future<List<int>> Function(String artifactId) contentOf;
  final Future<SessionChecks?> Function(
    String sessionId, {
    List<ProjectCheck>? only,
  })
  runChecks;
  final DateTime Function() now;

  @override
  Future<List<PipelineArtifactRef>> artifactsOf(String sessionId) async =>
      listArtifacts(sessionId);

  @override
  Future<String?> artifactText(String artifactId) async {
    try {
      return utf8.decode(await contentOf(artifactId), allowMalformed: true);
    } on Object {
      return null;
    }
  }

  @override
  Future<PipelineCheckRecord> check({
    required String sessionId,
    required String repositoryId,
    required String command,
    String? worktreePath,
    String? environmentId,
  }) async {
    final argv = command.trim().isEmpty
        ? null
        : splitCommandLine(command.trim());
    final only = argv == null || argv.isEmpty
        ? null
        : [
            ProjectCheck(
              id: 'pipeline:$sessionId',
              repositoryId: repositoryId,
              name: 'Pipeline check',
              command: argv,
              createdAt: now(),
            ),
          ];
    final SessionChecks? ran;
    try {
      ran = await runChecks(sessionId, only: only);
    } on StateError catch (error) {
      return PipelineCheckRecord(
        verdict: VerificationVerdict.inconclusive,
        summary: 'Nothing was checked: ${error.message}.',
        checkedAt: now(),
      );
    }
    if (ran == null) {
      return PipelineCheckRecord(
        verdict: VerificationVerdict.inconclusive,
        summary:
            'Nothing was checked: this checkout has no project checks and '
            'the stage names no command.',
        checkedAt: now(),
      );
    }
    final lines = [
      for (final check in ran.checks)
        '${check.name}: ${check.refusal ?? (check.timedOutAfter != null ? 'timed out' : 'exit ${check.exitCode ?? '?'}')}',
      if (ran.run.reason case final reason? when reason.isNotEmpty) reason,
    ];
    final failing = ran.checks
        .where((c) => c.exitCode != 0)
        .map((c) => c.output.trim())
        .where((o) => o.isNotEmpty)
        .map(_tail);
    return PipelineCheckRecord(
      verdict: ran.run.verdict ?? VerificationVerdict.inconclusive,
      summary: [...lines, ...failing].join('\n'),
      checkedAt: now(),
      verificationRunId: ran.run.id,
      identity: ran.run.identity,
    );
  }

  static String _tail(String output) {
    final lines = output.split('\n');
    return lines.length <= 30
        ? output
        : lines.sublist(lines.length - 30).join('\n');
  }
}

/// **The server's pipelines**: the runner over the store, answering the
/// app's requests and the MCP tools, every change told to every client.
class ServerPipelines implements PipelinesWork {
  ServerPipelines({
    required this.records,
    required StageLauncher launcher,
    required StageWatcher watcher,
    required StageEvidence evidence,
    required this.tell,
    required this.hasRepository,
    required DateTime Function() now,
    required String Function() newId,
    void Function(String message)? log,
  }) : _now = now,
       _newId = newId {
    runner = PipelineRunner(
      records: records,
      launcher: launcher,
      watcher: watcher,
      evidence: evidence,
      now: now,
      newId: newId,
      onChanged: (run) => tell([PipelineRunChanged(run)]),
      log: log,
    );
  }

  final PipelineRecords records;
  final void Function(List<DataChange> changes) tell;
  final bool Function(String repositoryId) hasRepository;
  final DateTime Function() _now;
  final String Function() _newId;
  late final PipelineRunner runner;

  /// Carries on every run a stopped server left running.
  void start() => runner.resume();

  /// Built-in templates first, then saved pipelines.
  List<PipelineDefinition> definitions() => [
    ...kPipelineTemplates,
    ...records.definitions(),
  ];

  /// The template or saved pipeline [idOrName] names.
  PipelineDefinition? definitionNamed(String idOrName) {
    final wanted = idOrName.trim().toLowerCase();
    for (final definition in definitions()) {
      if (definition.id == idOrName ||
          definition.name.toLowerCase() == wanted) {
        return definition;
      }
    }
    return null;
  }

  /// Starts [definition] on [repositoryId]; throws [ArgumentError] when it
  /// cannot run.
  PipelineRun startRun({
    required PipelineDefinition definition,
    required String repositoryId,
    required String input,
    String? startedBySessionId,
    bool byPerson = false,
  }) {
    if (!hasRepository(repositoryId)) {
      throw ArgumentError('That checkout is not in the workspace.');
    }
    return runner.start(
      definition: definition,
      repositoryId: repositoryId,
      input: input,
      startedBySessionId: startedBySessionId,
      byPerson: byPerson,
    );
  }

  @override
  Future<Object?> handle(PipelinesRequest<Object?> request) async {
    try {
      return await _handle(request);
    } on ArgumentError catch (error) {
      throw DataRefused.invalid('${error.message}');
    } on StateError catch (error) {
      throw DataRefused.invalid(error.message);
    }
  }

  Future<Object?> _handle(PipelinesRequest<Object?> request) async {
    switch (request) {
      case PipelinesList():
        return PipelinesSnapshot(
          templates: kPipelineTemplates,
          saved: records.definitions(),
          runs: records.runs(limit: kPipelineRunsListed),
        );
      case PipelineSave(:final pipeline):
        if (pipeline.builtIn ||
            kPipelineTemplates.any((t) => t.id == pipeline.id)) {
          throw ArgumentError(
            'A built-in template is not saved over; save a copy under its '
            'own name.',
          );
        }
        final refusal = pipelineDefinitionRefusal(pipeline);
        if (refusal != null) throw ArgumentError(refusal);
        final saved = pipeline.copyWith(
          id: pipeline.id.trim().isEmpty ? _newId() : pipeline.id,
          name: pipeline.name.trim(),
        );
        records.saveDefinition(saved, _now());
        tell([PipelineChanged(saved)]);
        return saved;
      case PipelineDelete(:final id):
        records.deleteDefinition(id);
        tell([PipelineRemoved(id)]);
        return const DataAck();
      case PipelineRunStart(
        :final definition,
        :final repositoryId,
        :final input,
      ):
        return startRun(
          definition: definition,
          repositoryId: repositoryId,
          input: input,
          byPerson: true,
        );
      case PipelineRunApprove(:final runId, :final handoff):
        return runner.approve(runId, handoff: handoff);
      case PipelineRunStop(:final runId):
        return runner.stop(runId);
      case PipelineRunRetry(:final runId):
        return runner.retry(runId);
      case PipelineRunSkip(:final runId):
        return runner.skip(runId);
    }
  }
}
