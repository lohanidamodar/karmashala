import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';

import 'checkout_reach.dart';

/// What a checkout still owes, read by the server the way the app's delivery
/// strip reads it: the branch, its base and upstream, dirty files, and — for
/// a session — its pull request. **Every reading that fails is null**, which
/// a tool says as "not recorded"; nothing here ever throws.
class CheckoutDeliveryReader {
  const CheckoutDeliveryReader(this._reach);

  final CheckoutReach _reach;

  /// The local half of [directory]'s state, measured against `origin/HEAD` of
  /// [repository] (the clone a worktree came from; [directory] itself when
  /// omitted).
  Future<SessionDelivery> local(
    EnvironmentPath directory, {
    EnvironmentPath? repository,
  }) async {
    final status = await _orNull(
      () => _reach.ask(directory, (git, at) => git.statusWithBranch(at)),
    );
    if (status == null) return SessionDelivery.unknown;

    final origin = await _origin(repository ?? directory);
    final base = origin.head;
    final (aheadBehind, lines) = await (
      base == null
          ? Future<AheadBehind?>.value()
          : _orNull(
              () => _reach.ask(
                directory,
                (git, at) => git.aheadBehind(at, base: base),
              ),
            ),
      _orNull(
        () => _reach.ask(directory, (git, at) => git.diffStat(at, base: base)),
      ),
    ).wait;

    return SessionDelivery(
      branch: status.branch,
      baseBranch: base,
      upstream: status.upstream,
      hasRemote: origin.hasRemote,
      remote: RemoteRepo.parse(origin.url),
      defaultBranch: origin.defaultBranch,
      dirtyFiles: status.changes.length,
      lines: lines,
      aheadOfBase: aheadBehind?.ahead,
      behindBase: aheadBehind?.behind,
      unpushed: status.aheadOfUpstream,
    );
  }

  /// A worktree's state, measured against the branch [repository] has out
  /// when no `origin/HEAD` is recorded — a local question with a local answer.
  Future<SessionDelivery> worktree(
    EnvironmentPath repository,
    EnvironmentPath worktree,
  ) async {
    final (delivery, parent) = await (
      local(worktree, repository: repository),
      local(repository),
    ).wait;
    if (delivery.baseBranch != null) return delivery;

    final base = parent.branch;
    if (base == null || base == delivery.branch) return delivery;
    final aheadBehind = await _orNull(
      () => _reach.ask(worktree, (git, at) => git.aheadBehind(at, base: base)),
    );
    final lines = await _orNull(
      () => _reach.ask(worktree, (git, at) => git.diffStat(at, base: base)),
    );
    return delivery.copyWith(
      baseBranch: base,
      aheadOfBase: aheadBehind?.ahead,
      behindBase: aheadBehind?.behind,
      lines: lines,
    );
  }

  /// Everything [session]'s strip shows: the local reading of where it works
  /// (its worktree, else [repository]), its pull request, the repository's
  /// merge settings and — only when a merge reads `BLOCKED` — the branch
  /// protection behind it. [agentRunning] is the caller's to know.
  Future<SessionDelivery> session(
    Session session,
    Repository? repository, {
    required bool agentRunning,
  }) async {
    if (repository == null) return SessionDelivery.unknown;
    final worktree = session.worktree;
    if (session.isArchived) {
      // The directory is gone: asking git would describe whatever someone
      // else has since created there.
      return SessionDelivery(hasWorktree: worktree != null, archived: true);
    }
    final local = (worktree == null
        ? await this.local(repository.path)
        : await this.worktree(repository.path, worktree));
    final directory = worktree ?? repository.path;

    final pullRequest = await _pullRequest(directory, local);
    final forge = pullRequest == null || !pullRequest.isOpen
        ? kUnknownForgePolicy
        : await _orNull(
                () => _reach
                    .gitHubFor(directory)
                    .forgePolicyFor(directory, number: pullRequest.number),
              ) ??
              kUnknownForgePolicy;
    return local.copyWith(
      hasWorktree: worktree != null,
      pullRequest: pullRequest?.withUnresolvedReviewThreads(
        forge.unresolvedReviewThreads,
      ),
      mergeStrategies: forge.strategies,
      branchProtection: await _protection(directory, pullRequest),
      agentRunning: agentRunning,
    );
  }

  /// The pull request for [local]'s branch: null for none, and for a `gh`
  /// that could not tell.
  Future<PullRequestSnapshot?> _pullRequest(
    EnvironmentPath directory,
    SessionDelivery local,
  ) async {
    final branch = local.branch;
    if (branch == null || local.hasRemote != true) return null;
    return _orNull(
      () =>
          _reach.gitHubFor(directory).pullRequestFor(directory, branch: branch),
    );
  }

  /// The base branch's protection, asked only when the pull request is
  /// already `BLOCKED` — the one state it can explain.
  Future<BranchProtection> _protection(
    EnvironmentPath directory,
    PullRequestSnapshot? pullRequest,
  ) async {
    if (pullRequest == null || !pullRequest.isOpen) {
      return BranchProtection.unknown;
    }
    if (pullRequest.mergeStateStatus != MergeStateStatus.blocked) {
      return BranchProtection.unknown;
    }
    final base = pullRequest.baseRefName;
    if (base == null) return BranchProtection.unknown;
    return await _orNull(
          () => _reach
              .gitHubFor(directory)
              .branchProtectionFor(directory, branch: base),
        ) ??
        BranchProtection.unknown;
  }

  /// `origin`'s URL and recorded default branch; nothing at all when there is
  /// no `origin`, or git could not say.
  Future<RepositoryOrigin> _origin(EnvironmentPath repository) async {
    final url = await _orNull(
      () => _reach.ask(repository, (git, at) => git.remoteUrl(at)),
    );
    if (url == null) return RepositoryOrigin.none;
    return RepositoryOrigin(
      url: url,
      head: await _orNull(
        () => _reach.ask(repository, (git, at) => git.originHead(at)),
      ),
    );
  }

  /// Runs [probe], turning any failure into null ("could not tell").
  static Future<T?> _orNull<T>(Future<T?> Function() probe) async {
    try {
      return await probe();
    } on Object {
      return null;
    }
  }
}
