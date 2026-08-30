import '../../git/domain/diff_stat.dart';
import '../../git/domain/remote_repo.dart';
import '../../github/domain/pull_request_snapshot.dart';
import 'delivery_stage.dart';

/// Everything one session's row and strip need to say where its work stands.
///
/// **Every field is nullable and `null` always means "could not tell"**, never
/// "no" — the same rule Loop 33's `HandoffRepoState` set, kept because the
/// probes behind these fields fail for a dozen boring reasons (git absent, `gh`
/// logged out, a base ref not fetched) and a delivery strip that reads a failed
/// probe as a definite answer will hide the action the user came for.
///
/// The two exceptions are [archived] and [hasWorktree], which come from the
/// database rather than a process and are therefore always known.
class SessionDelivery {
  const SessionDelivery({
    this.branch,
    this.baseBranch,
    this.upstream,
    this.hasRemote,
    this.remote,
    this.defaultBranch,
    this.dirtyFiles,
    this.lines,
    this.aheadOfBase,
    this.behindBase,
    this.unpushed,
    this.pullRequest,
    this.hasWorktree = false,
    this.agentRunning,
    this.archived = false,
  });

  /// Nothing is known: no checkout, or every probe failed.
  static const unknown = SessionDelivery();

  /// The branch checked out where this session works.
  final String? branch;

  /// What [aheadOfBase] and [behindBase] were measured against — `origin/main`
  /// when the remote's default branch is known, otherwise the branch the
  /// repository itself has checked out.
  final String? baseBranch;

  /// The branch's upstream (`origin/work`). Null means it has none, which is
  /// how "never pushed" is established.
  final String? upstream;

  /// Whether the repository has an `origin`. `false` comes straight from git.
  final bool? hasRemote;

  /// Where `origin` points, as a page. Null when there is no remote or its URL
  /// names something with no web address.
  final RemoteRepo? remote;

  /// The remote's default branch, per `gh repo view`.
  final String? defaultBranch;

  /// Files with working-tree changes, untracked ones included.
  final int? dirtyFiles;

  /// Lines added and removed against [baseBranch] — the session's whole diff,
  /// committed and uncommitted alike.
  final DiffStat? lines;

  final int? aheadOfBase;
  final int? behindBase;

  /// Commits the branch has that its upstream does not. Null when there is no
  /// upstream (never pushed) *or* when git could not say; [upstream] tells the
  /// two apart.
  final int? unpushed;

  final PullRequestSnapshot? pullRequest;

  /// Whether this session works in a worktree of its own — the only thing
  /// archiving can remove.
  final bool hasWorktree;

  /// Whether an agent is live in this session right now. Null when unasked.
  final bool? agentRunning;

  /// Whether the worktree has been archived away. Its transcript, review notes
  /// and checkpoints are untouched.
  final bool archived;

  /// Whether the branch has commits that no remote has.
  bool get hasUnpushedWork => (unpushed ?? 0) > 0;

  /// Whether the working tree has changes to record.
  bool get isDirty => (dirtyFiles ?? 0) > 0;

  /// Whether the current branch is the one a PR would be proposed *against*.
  bool get isOnDefaultBranch =>
      branch != null && defaultBranch != null && branch == defaultBranch;

  /// The furthest point this work has reached. See [DeliveryStage].
  DeliveryStage get stage {
    if (archived) return DeliveryStage.archived;

    final pr = pullRequest;
    if (pr != null) {
      if (pr.state == PullRequestState.merged) return DeliveryStage.merged;
      if (pr.isOpen) {
        return switch (pr.checks.state) {
          ChecksState.failing => DeliveryStage.checksFailing,
          ChecksState.passing => DeliveryStage.checksPassing,
          // No checks and pending checks are the same thing to a stage: the
          // pull request is open and has not been judged.
          ChecksState.pending || ChecksState.none => DeliveryStage.prOpen,
        };
      }
      // A closed-unmerged PR is not progress; the local facts decide.
    }

    if (isDirty) return DeliveryStage.working;
    if ((aheadOfBase ?? 0) > 0) {
      // Pushed only on a *positive* zero from git. No upstream, or a count we
      // could not read, both stop at committed — claiming work is on the remote
      // when it is not is the one mistake with a cost.
      if (upstream != null && unpushed == 0) return DeliveryStage.pushed;
      return DeliveryStage.committed;
    }
    return DeliveryStage.working;
  }

  /// `+120 −18`, or null when no line counts were read.
  String? get lineLabel {
    final stat = lines;
    if (stat == null || stat.isEmpty) return null;
    return '+${stat.added} −${stat.removed}';
  }

  SessionDelivery copyWith({
    String? branch,
    String? baseBranch,
    String? upstream,
    bool? hasRemote,
    RemoteRepo? remote,
    String? defaultBranch,
    int? dirtyFiles,
    DiffStat? lines,
    int? aheadOfBase,
    int? behindBase,
    int? unpushed,
    PullRequestSnapshot? pullRequest,
    bool? hasWorktree,
    bool? agentRunning,
    bool? archived,
  }) => SessionDelivery(
    branch: branch ?? this.branch,
    baseBranch: baseBranch ?? this.baseBranch,
    upstream: upstream ?? this.upstream,
    hasRemote: hasRemote ?? this.hasRemote,
    remote: remote ?? this.remote,
    defaultBranch: defaultBranch ?? this.defaultBranch,
    dirtyFiles: dirtyFiles ?? this.dirtyFiles,
    lines: lines ?? this.lines,
    aheadOfBase: aheadOfBase ?? this.aheadOfBase,
    behindBase: behindBase ?? this.behindBase,
    unpushed: unpushed ?? this.unpushed,
    pullRequest: pullRequest ?? this.pullRequest,
    hasWorktree: hasWorktree ?? this.hasWorktree,
    agentRunning: agentRunning ?? this.agentRunning,
    archived: archived ?? this.archived,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionDelivery &&
      other.branch == branch &&
      other.baseBranch == baseBranch &&
      other.upstream == upstream &&
      other.hasRemote == hasRemote &&
      other.remote == remote &&
      other.defaultBranch == defaultBranch &&
      other.dirtyFiles == dirtyFiles &&
      other.lines == lines &&
      other.aheadOfBase == aheadOfBase &&
      other.behindBase == behindBase &&
      other.unpushed == unpushed &&
      other.pullRequest == pullRequest &&
      other.hasWorktree == hasWorktree &&
      other.agentRunning == agentRunning &&
      other.archived == archived;

  @override
  int get hashCode => Object.hash(
    branch,
    baseBranch,
    upstream,
    hasRemote,
    remote,
    defaultBranch,
    dirtyFiles,
    lines,
    aheadOfBase,
    behindBase,
    unpushed,
    Object.hash(pullRequest, hasWorktree, agentRunning, archived),
  );

  @override
  String toString() =>
      'SessionDelivery(${branch ?? '?'}, ${stage.name}, '
      'dirty $dirtyFiles, ahead $aheadOfBase, pr ${pullRequest?.number})';
}
