import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/domain/agent_installation.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import '../../git/domain/file_change.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
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

/// One agent that never got started, and why.
///
/// Named rather than swallowed because the whole point of a fan-out is that
/// several agents run the *same* prompt: "three of five started" is a different
/// comparison from the one the user asked for, and they have to be told which
/// two are missing before they read the diffs.
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

/// The outcome of a fan-out: what is running, what refused to start, and the
/// durable [Comparison] that records both.
///
/// `Future.wait` used to be the whole of [FanOutService.launch], which meant a
/// single failing agent threw and **discarded every successful launch with it**
/// — sessions that were already running, with worktrees already created, now
/// unreferenced by anything the UI could see. Returning both halves is what
/// makes the successes survive their unlucky sibling.
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

  /// Starts [prompt] on every installation in [installations], each in its own
  /// worktree, and records the whole thing as a [Comparison].
  ///
  /// Every agent is launched; one that throws becomes a [FanOutFailure] rather
  /// than cancelling the others' results. Only the *inputs* are rejected
  /// outright, before anything is created — and therefore before any comparison
  /// row is written.
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

  /// Rebuilds the live handles for a stored [comparison].
  ///
  /// This is what makes a comparison a place you come back to: after a restart
  /// nothing is in memory, and the session rows plus the candidate records are
  /// enough to act again. A candidate whose session row is gone is skipped —
  /// its *record* still reads in the view, there is simply nothing left to
  /// merge or discard.
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

  /// Reads [result]'s current diff **and records what it showed**.
  ///
  /// The recording is the point: `git diff` needs a directory, and the whole
  /// promise of a persistent comparison is that it still says what each agent
  /// did after that directory has been removed.
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
  ///
  /// Files come from `git status` — it dedupes a file that is both staged and
  /// modified, and it is the only one of the three that sees an untracked file.
  /// Lines come from the staged and unstaged diffs together, because an agent
  /// that ran `git add` and stopped there has an empty unstaged diff and a full
  /// day's work in the index. Commits come from `rev-list`, and are the only
  /// number left once an agent commits and the working tree goes clean.
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

  /// Merges [result]'s session branch into the repository's current branch, and
  /// records the winner and the commit it landed on.
  ///
  /// Merging is all this does. Removing the worktrees of the agents that did
  /// not win is [discardLosers] — a second, deliberate action, because a merge
  /// that also deleted four other agents' work as a side effect would be a
  /// destructive operation the user never asked for and could not decline.
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

  /// Removes the worktrees of every result in [results] except [winner].
  ///
  /// A fan-out leaves one worktree per agent behind, and nothing used to take
  /// them away: five agents compared meant four `.chitragupta-worktrees/…`
  /// directories and four checked-out branches sitting there indefinitely.
  ///
  /// It refuses, rather than asks forgiveness, in two cases:
  ///
  /// * **The session is still running.** Deleting the directory a live agent is
  ///   working in is not cleanup.
  /// * **The worktree has uncommitted changes.** That is work no branch holds;
  ///   removing it destroys the only copy. Pass the session's id in
  ///   [discardUncommittedFor] to say, for that specific session, that it may
  ///   go anyway — a per-session confirmation, not a global `force` flag,
  ///   because the user confirms one dialog about one agent's work.
  ///
  /// Branches are deliberately left alone. A branch is recoverable and cheap; a
  /// worktree directory is the thing that accumulates. Removal itself goes
  /// through [WorktreeService], so this is the same lifecycle Loop 5 built and
  /// not a second way to unmake a worktree.
  ///
  /// The candidate record is *not* removed with the directory. It is marked
  /// `worktreeRemoved` and keeps the last diff stat read from it, which is the
  /// only account of that agent's work that survives.
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
