import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import 'package:karmashala_git/git.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';
import '../../sessions/domain/session_naming.dart';
import '../domain/comparison.dart';
import '../domain/diff_counts.dart';
import 'comparison_providers.dart';

/// One agent's run of the shared prompt, in its own worktree.
class FanOutResult {
  const FanOutResult({
    required this.session,
    required this.agentId,
    required this.repository,
    this.candidate,
  });
  final Session session;
  final String agentId;
  final Repository repository;

  /// The persisted record of this run, when there is one. Optional only so a
  /// caller can name a session that was never part of a stored comparison.
  final ComparisonCandidate? candidate;
}

/// One agent that never got started, and why. Named rather than swallowed:
/// "three of five started" is a different comparison from the one asked for.
class FanOutFailure {
  const FanOutFailure({
    required this.installation,
    required this.error,
    this.candidate,
  });

  final AgentInstallation installation;
  final Object error;

  /// The failed candidate's record. A failure is stored, not dropped: a
  /// comparison of three where one never started is not a comparison of two.
  final ComparisonCandidate? candidate;

  String get agentId => installation.agentId;
}

/// The outcome of a fan-out: what is running, what refused, and the durable
/// [Comparison]. Both halves, so successes survive an unlucky sibling.
class FanOutLaunch {
  const FanOutLaunch({
    required this.started,
    required this.failures,
    required this.comparison,
  });

  /// The agents that are running, in the order they were requested.
  final List<FanOutResult> started;

  /// The agents that could not be started, in the order they were requested.
  final List<FanOutFailure> failures;

  /// The record this launch wrote. It outlives the dialog, the worktrees and
  /// the sessions.
  final Comparison comparison;

  /// How many agents were asked for.
  int get requested => started.length + failures.length;

  bool get hasFailures => failures.isNotEmpty;

  /// A one-line account of a partial launch, or `null` when everything started.
  String? get partialSummary => failures.isEmpty
      ? null
      : '${started.length} of $requested agents started; '
            '${failures.length} failed.';
}

/// Why a losing worktree was left alone.
enum FanOutKeepReason {
  /// Its session still has a live pane. Removing the directory out from under a
  /// running agent is not a cleanup, it is a crash.
  stillRunning,

  /// It holds uncommitted work nobody has said may go.
  uncommittedChanges,
}

/// A losing worktree that was deliberately not removed.
class FanOutKept {
  const FanOutKept({
    required this.result,
    required this.reason,
    this.changes = const [],
  });

  final FanOutResult result;
  final FanOutKeepReason reason;

  /// The uncommitted changes that stopped it, for
  /// [FanOutKeepReason.uncommittedChanges].
  final List<FileChange> changes;
}

/// A losing worktree that git refused to remove.
class FanOutDiscardFailure {
  const FanOutDiscardFailure({required this.result, required this.error});

  final FanOutResult result;
  final Object error;

  String get agentId => result.agentId;
}

/// What [FanOutService.discardLosers] actually did.
class FanOutDiscard {
  const FanOutDiscard({
    required this.removed,
    required this.kept,
    required this.failures,
  });

  /// Sessions whose worktree is gone.
  final List<FanOutResult> removed;

  /// Sessions whose worktree was left in place, and why.
  final List<FanOutKept> kept;

  /// Sessions whose worktree removal was attempted and failed.
  final List<FanOutDiscardFailure> failures;

  bool get isEmpty => removed.isEmpty && kept.isEmpty && failures.isEmpty;
}

class FanOutService {
  FanOutService(this.ref);
  final Ref ref;

  /// Starts [prompt] on every installation, each in its own worktree. One that
  /// throws becomes a [FanOutFailure]; only the *inputs* are rejected outright.
  Future<FanOutLaunch> launch({
    required Repository repository,
    required List<AgentInstallation> installations,
    required String prompt,
  }) async {
    final message = prompt.trim();
    if (message.isEmpty) throw ArgumentError('Prompt cannot be empty.');
    if (installations.length < 2) {
      throw ArgumentError('Choose at least two agent installations.');
    }
    final unique = installations.map((i) => i.id).toSet();
    if (unique.length != installations.length) {
      throw ArgumentError('Each installation can only run once.');
    }

    final outcomes = await Future.wait([
      for (final installation in installations)
        _launchOne(
          repository: repository,
          installation: installation,
          message: message,
        ),
    ]);

    final ids = ref.read(idGeneratorProvider);
    final comparisonId = ids.newId();
    final candidates = <ComparisonCandidate>[
      for (var i = 0; i < installations.length; i++)
        _candidateFor(
          id: ids.newId(),
          comparisonId: comparisonId,
          position: i,
          installation: installations[i],
          outcome: outcomes[i],
        ),
    ];
    final comparison = Comparison(
      id: comparisonId,
      repositoryId: repository.id,
      prompt: message,
      createdAt: ref.read(clockProvider).nowUtc(),
      candidates: candidates,
    );
    ref.read(comparisonDaoProvider).insert(comparison);
    ref.read(comparisonsProvider.notifier).reload();

    return FanOutLaunch(
      comparison: comparison,
      started: [
        for (var i = 0; i < installations.length; i++)
          if (outcomes[i].result case final result?)
            FanOutResult(
              session: result.session,
              agentId: result.agentId,
              repository: result.repository,
              candidate: candidates[i],
            ),
      ],
      failures: [
        for (var i = 0; i < installations.length; i++)
          if (outcomes[i].failure case final failure?)
            FanOutFailure(
              installation: failure.installation,
              error: failure.error,
              candidate: candidates[i],
            ),
      ],
    );
  }

  ComparisonCandidate _candidateFor({
    required String id,
    required String comparisonId,
    required int position,
    required AgentInstallation installation,
    required ({FanOutResult? result, FanOutFailure? failure}) outcome,
  }) {
    final session = outcome.result?.session;
    return ComparisonCandidate(
      id: id,
      comparisonId: comparisonId,
      position: position,
      installationId: installation.id,
      agentId: installation.agentId,
      launch: session == null
          ? CandidateLaunchState.failed
          : CandidateLaunchState.started,
      sessionId: session?.id,
      worktree: session?.worktree,
      branch: session == null ? null : sessionBranchName(session.id),
      failure: outcome.failure == null ? null : '${outcome.failure!.error}',
    );
  }

  Future<({FanOutResult? result, FanOutFailure? failure})> _launchOne({
    required Repository repository,
    required AgentInstallation installation,
    required String message,
  }) async {
    try {
      final launched = await ref
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository,
              installation: installation,
              title: 'Compare · ${installation.agentId}',
              purpose: SessionPurpose.newSession,
              useWorktree: true,
              firstMessage: message,
            ),
          );
      return (
        result: FanOutResult(
          session: launched.session,
          agentId: installation.agentId,
          repository: repository,
        ),
        failure: null,
      );
    } on Object catch (error) {
      return (
        result: null,
        failure: FanOutFailure(installation: installation, error: error),
      );
    }
  }

  /// Rebuilds the live handles for a stored [comparison], which is what makes it
  /// a place you come back to. A candidate with no session row is skipped.
  List<FanOutResult> resultsFor(Comparison comparison) {
    final repository = ref
        .read(repositoryDaoProvider)
        .getById(comparison.repositoryId);
    if (repository == null) return const [];
    final sessions = ref.read(sessionDaoProvider);
    return [
      for (final candidate in comparison.candidates)
        if (candidate.sessionId case final sessionId?)
          if (sessions.getById(sessionId) case final session?)
            FanOutResult(
              session: session,
              agentId: candidate.agentId,
              repository: repository,
              candidate: candidate,
            ),
    ];
  }

  /// The live handle for one candidate, or `null` when its session is gone.
  FanOutResult? resultFor(
    Comparison comparison,
    ComparisonCandidate candidate,
  ) {
    for (final result in resultsFor(comparison)) {
      if (result.candidate?.id == candidate.id) return result;
    }
    return null;
  }

  /// Reads [result]'s current diff **and records what it showed** — the whole
  /// promise is that it still reads after the directory is gone.
  Future<String> diff(FanOutResult result) async {
    final worktree = result.session.worktree;
    if (worktree == null) return '';
    if (result.candidate?.worktreeRemoved ?? false) return '';
    final changes = ref.read(changesServiceProvider);
    final unstaged = await changes.diff(worktree);
    final candidate = result.candidate;
    if (candidate != null) {
      await _recordDiff(
        candidate: candidate,
        worktree: worktree,
        repository: result.repository,
        unstaged: unstaged,
      );
    }
    return unstaged;
  }

  /// Captures the diff stat for [candidate] without returning the diff text.
  Future<CandidateDiffStat?> captureDiffStat(FanOutResult result) async {
    final worktree = result.session.worktree;
    final candidate = result.candidate;
    if (worktree == null || candidate == null) return null;
    if (candidate.worktreeRemoved) return candidate.diff;
    return _recordDiff(
      candidate: candidate,
      worktree: worktree,
      repository: result.repository,
      unstaged: await ref.read(changesServiceProvider).diff(worktree),
    );
  }

  /// Counts what a worktree currently holds and stores it on the candidate.
  /// Files from `git status`, lines from both diffs, commits from `rev-list`.
  Future<CandidateDiffStat> _recordDiff({
    required ComparisonCandidate candidate,
    required EnvironmentPath worktree,
    required Repository repository,
    required String unstaged,
  }) async {
    final changes = ref.read(changesServiceProvider);
    var lines = parseDiffLineCounts(unstaged);
    var files = 0;
    int? commits;
    try {
      lines += parseDiffLineCounts(await changes.diff(worktree, staged: true));
      files = (await changes.changes(worktree)).length;
      final base = await changes.currentBranch(repository.path);
      if (base != null) {
        commits = await changes.commitsAhead(worktree, base: base);
      }
    } on Object {
      // A partial count is worth more than no record at all: the unstaged diff
      // has already been read, and it is the number the user is looking at.
    }

    final stat = CandidateDiffStat(
      filesChanged: files,
      insertions: lines.insertions,
      deletions: lines.deletions,
      commits: commits,
      capturedAt: ref.read(clockProvider).nowUtc(),
    );
    ref.read(comparisonDaoProvider).updateDiff(candidate.id, stat);
    ref.read(comparisonsProvider.notifier).reload();
    return stat;
  }

  /// Names [result] the winner of its comparison without merging anything.
  void markWinner(FanOutResult result) {
    final candidate = result.candidate;
    if (candidate == null) return;
    ref
        .read(comparisonDaoProvider)
        .updateWinner(candidate.comparisonId, candidate.id);
    ref.read(comparisonsProvider.notifier).reload();
  }

  /// Merges [result]'s branch and records the winner. Merging is all it does:
  /// removing the losers' worktrees is [discardLosers], a second, named action.
  Future<void> mergeWinner(FanOutResult result) async {
    final worktree = result.session.worktree;
    if (worktree == null) throw StateError('This result has no worktree.');
    final changes = ref.read(changesServiceProvider);
    final pending = await changes.changes(worktree);
    if (pending.isNotEmpty) {
      throw StateError(
        'The winner still has uncommitted changes. Ask the agent to commit '
        'before merging it.',
      );
    }
    await changes.mergeBranch(
      result.repository.path,
      sessionBranchName(result.session.id),
    );

    final candidate = result.candidate;
    if (candidate == null) return;
    String? merged;
    try {
      final log = await changes.log(result.repository.path, limit: 1);
      merged = log.isEmpty ? null : log.first.sha;
    } on Object {
      // The merge succeeded; not being able to name its commit does not undo it.
    }
    ref
        .read(comparisonDaoProvider)
        .updateOutcome(
          candidate.comparisonId,
          outcome: ComparisonOutcome.merged,
          winnerCandidateId: candidate.id,
          mergedCommit: merged,
          finishedAt: ref.read(clockProvider).nowUtc(),
        );
    ref.read(comparisonsProvider.notifier).reload();
  }

  /// Closes a comparison out without merging anything.
  void abandon(Comparison comparison) {
    ref
        .read(comparisonDaoProvider)
        .updateOutcome(
          comparison.id,
          outcome: ComparisonOutcome.discarded,
          winnerCandidateId: comparison.winnerCandidateId,
          mergedCommit: comparison.mergedCommit,
          finishedAt: ref.read(clockProvider).nowUtc(),
        );
    ref.read(comparisonsProvider.notifier).reload();
  }

  /// Removes the worktrees of every result except [winner]. It refuses a running
  /// session and an uncommitted tree; branches, being cheap, are left alone.
  Future<FanOutDiscard> discardLosers(
    List<FanOutResult> results, {
    required FanOutResult winner,
    Set<String> discardUncommittedFor = const {},
  }) async {
    final removed = <FanOutResult>[];
    final kept = <FanOutKept>[];
    final failures = <FanOutDiscardFailure>[];
    final dao = ref.read(comparisonDaoProvider);

    for (final loser in results) {
      if (loser.session.id == winner.session.id) continue;
      final worktree = loser.session.worktree;
      if (worktree == null) continue;
      if (loser.candidate?.worktreeRemoved ?? false) continue;

      try {
        if (ref.read(sessionLauncherProvider).livePaneFor(loser.session.id) !=
            null) {
          kept.add(
            FanOutKept(result: loser, reason: FanOutKeepReason.stillRunning),
          );
          continue;
        }

        final changes = await ref
            .read(changesServiceProvider)
            .changes(worktree);
        final confirmed = discardUncommittedFor.contains(loser.session.id);
        if (changes.isNotEmpty && !confirmed) {
          kept.add(
            FanOutKept(
              result: loser,
              reason: FanOutKeepReason.uncommittedChanges,
              changes: changes,
            ),
          );
          continue;
        }

        // Read the diff before the directory goes: afterwards there is nothing
        // left to ask, and this stat is the record of what this agent did.
        // Failing to read it must not stop the removal the user asked for.
        try {
          if (loser.candidate case final candidate?) {
            await _recordDiff(
              candidate: candidate,
              worktree: worktree,
              repository: loser.repository,
              unstaged: await ref.read(changesServiceProvider).diff(worktree),
            );
          }
        } on Object {
          // The stat is a nicety; the removal is the job.
        }

        await ref
            .read(worktreeServiceProvider)
            .remove(
              loser.repository.path,
              worktree,
              // Git refuses to remove a dirty worktree without this, which is
              // exactly the check above — so it is only ever set for a session
              // the caller named.
              force: changes.isNotEmpty,
            );
        removed.add(loser);
        if (loser.candidate case final candidate?) {
          dao.markWorktreeRemoved(candidate.id);
        }
      } on Object catch (error) {
        failures.add(FanOutDiscardFailure(result: loser, error: error));
      }
    }

    if (removed.isNotEmpty) ref.read(comparisonsProvider.notifier).reload();
    return FanOutDiscard(removed: removed, kept: kept, failures: failures);
  }
}

final fanOutServiceProvider = Provider<FanOutService>(FanOutService.new);
