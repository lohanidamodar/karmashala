import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/domain/agent_installation.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';

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
          'session/${result.session.id.substring(0, 8)}',
        );
  }
}

final fanOutServiceProvider = Provider<FanOutService>(FanOutService.new);
