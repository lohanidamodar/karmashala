import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/domain/agent_installation.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import '../../git/domain/file_change.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';
import '../../sessions/domain/session_naming.dart';

/// One agent's run of the shared prompt, in its own worktree.
class FanOutResult {
  const FanOutResult({
    required this.session,
    required this.agentId,
    required this.repository,
  });
  final Session session;
  final String agentId;
  final Repository repository;
}

/// One agent that never got started, and why.
///
/// Named rather than swallowed because the whole point of a fan-out is that
/// several agents run the *same* prompt: "three of five started" is a different
/// comparison from the one the user asked for, and they have to be told which
/// two are missing before they read the diffs.
class FanOutFailure {
  const FanOutFailure({required this.installation, required this.error});

  final AgentInstallation installation;
  final Object error;

  String get agentId => installation.agentId;
}

/// The outcome of a fan-out: what is running, and what refused to start.
///
/// `Future.wait` used to be the whole of [FanOutService.launch], which meant a
/// single failing agent threw and **discarded every successful launch with it**
/// — sessions that were already running, with worktrees already created, now
/// unreferenced by anything the UI could see. Returning both halves is what
/// makes the successes survive their unlucky sibling.
class FanOutLaunch {
  const FanOutLaunch({required this.started, required this.failures});

  /// The agents that are running, in the order they were requested.
  final List<FanOutResult> started;

  /// The agents that could not be started, in the order they were requested.
  final List<FanOutFailure> failures;

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
  /// worktree.
  ///
  /// Every agent is launched; one that throws becomes a [FanOutFailure] rather
  /// than cancelling the others' results. Only the *inputs* are rejected
  /// outright, before anything is created.
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

    return FanOutLaunch(
      started: [for (final o in outcomes) ?o.result],
      failures: [for (final o in outcomes) ?o.failure],
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

  Future<String> diff(FanOutResult result) {
    final worktree = result.session.worktree;
    if (worktree == null) return Future.value('');
    return ref.read(changesServiceProvider).diff(worktree);
  }

  /// Merges [result]'s session branch into the repository's current branch.
  ///
  /// Merging is all this does. Removing the worktrees of the agents that did
  /// not win is [discardLosers] — a second, deliberate action, because a merge
  /// that also deleted four other agents' work as a side effect would be a
  /// destructive operation the user never asked for and could not decline.
  Future<void> mergeWinner(FanOutResult result) async {
    final worktree = result.session.worktree;
    if (worktree == null) throw StateError('This result has no worktree.');
    final changes = await ref.read(changesServiceProvider).changes(worktree);
    if (changes.isNotEmpty) {
      throw StateError(
        'The winner still has uncommitted changes. Ask the agent to commit '
        'before merging it.',
      );
    }
    await ref
        .read(changesServiceProvider)
        .mergeBranch(
          result.repository.path,
          sessionBranchName(result.session.id),
        );
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
  Future<FanOutDiscard> discardLosers(
    List<FanOutResult> results, {
    required FanOutResult winner,
    Set<String> discardUncommittedFor = const {},
  }) async {
    final removed = <FanOutResult>[];
    final kept = <FanOutKept>[];
    final failures = <FanOutDiscardFailure>[];

    for (final loser in results) {
      if (loser.session.id == winner.session.id) continue;
      final worktree = loser.session.worktree;
      if (worktree == null) continue;

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
      } on Object catch (error) {
        failures.add(FanOutDiscardFailure(result: loser, error: error));
      }
    }

    return FanOutDiscard(removed: removed, kept: kept, failures: failures);
  }
}

final fanOutServiceProvider = Provider<FanOutService>(FanOutService.new);
