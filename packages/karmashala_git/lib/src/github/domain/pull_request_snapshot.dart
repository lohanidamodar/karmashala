/// Where a pull request stands, as `gh pr view --json` reports it.
enum PullRequestState {
  open,
  merged,
  closed;

  static PullRequestState? parse(String? value) =>
      switch (value?.toUpperCase()) {
        'OPEN' => PullRequestState.open,
        'MERGED' => PullRequestState.merged,
        'CLOSED' => PullRequestState.closed,
        _ => null,
      };
}

/// What review has concluded. `none` is "nobody has reviewed", which is a fact;
/// a decision we could not read arrives as null instead.
enum ReviewDecision {
  approved,
  changesRequested,
  reviewRequired,
  none;

  static ReviewDecision? parse(String? value) => switch (value?.toUpperCase()) {
    'APPROVED' => ReviewDecision.approved,
    'CHANGES_REQUESTED' => ReviewDecision.changesRequested,
    'REVIEW_REQUIRED' => ReviewDecision.reviewRequired,
    '' || null => ReviewDecision.none,
    _ => null,
  };
}

/// GitHub's own one-word answer to "why can this not be merged right now?",
/// from `gh pr view --json mergeStateStatus`.
///
/// **The forge's opinion, and worth more than ours**: the same computation that
/// greys out GitHub's own merge button, so [behind] means behind the *remote's*
/// base rather than behind whatever `origin/main` this clone last fetched.
///
/// It is one value with a priority — dirty → blocked → behind → unstable → clean
/// — so it **masks**: `!= behind` is never evidence a branch is up to date, and
/// every read of it is written as a positive test. [blocked] is the common case
/// in a protected repository, not an alarm.
enum MergeStateStatus {
  /// Nothing is in the way; GitHub would merge this now.
  clean,

  /// The base branch has moved on and the repository requires branches to be
  /// current before they merge.
  behind,

  /// Something GitHub enforces says no — an unsatisfied branch-protection
  /// rule, a required review, an unresolved conversation, a required check
  /// that has not reported. It does not say which.
  blocked,

  /// The merge would conflict — the same fact as `mergeable: CONFLICTING`, kept
  /// separately because either one arriving alone establishes it.
  dirty,

  /// It is a draft. Rarely seen in practice — a protected repository answers
  /// `BLOCKED` for a draft too, which is why draftness is read off `isDraft`
  /// and never off this field.
  draft,

  /// A pre-receive hook stands between the branch and the base.
  hasHooks,

  /// A non-required check is failing or still running. Not a blocker.
  unstable;

  /// GitHub's `UNKNOWN` becomes **null**, not a value of this enum.
  ///
  /// It means "the mergeability computation has not finished", and null is
  /// "could not tell" everywhere in this pipeline.
  static MergeStateStatus? parse(String? value) =>
      switch (value?.toUpperCase()) {
        'CLEAN' => MergeStateStatus.clean,
        'BEHIND' => MergeStateStatus.behind,
        'BLOCKED' => MergeStateStatus.blocked,
        'DIRTY' => MergeStateStatus.dirty,
        'DRAFT' => MergeStateStatus.draft,
        'HAS_HOOKS' => MergeStateStatus.hasHooks,
        'UNSTABLE' => MergeStateStatus.unstable,
        _ => null,
      };
}

/// The one-word verdict on a pull request's checks.
enum ChecksState {
  /// Every check finished and none failed.
  passing,

  /// At least one check failed. **Failure beats pending**: a red check is news
  /// while its neighbours are still running, and waiting for the rest to finish
  /// before saying so would delay the only signal worth interrupting for.
  failing,

  /// Nothing failed and something is still running.
  pending,

  /// The pull request has no checks at all. Not the same as passing.
  none,
}

/// How many checks are in each bucket, and the verdict that follows.
class ChecksSummary {
  const ChecksSummary({
    this.passed = 0,
    this.failed = 0,
    this.pending = 0,
    this.skipped = 0,
  });

  static const none = ChecksSummary();

  final int passed;
  final int failed;
  final int pending;

  /// Skipped and neutral runs. Counted apart from [passed] because "did not
  /// run" is not "went green", and folded in with it for the verdict because
  /// neither blocks a merge.
  final int skipped;

  int get total => passed + failed + pending + skipped;

  ChecksState get state {
    if (total == 0) return ChecksState.none;
    if (failed > 0) return ChecksState.failing;
    if (pending > 0) return ChecksState.pending;
    return ChecksState.passing;
  }

  /// `3/4 passed`, or null when there are no checks to describe.
  String? get label {
    if (total == 0) return null;
    return switch (state) {
      ChecksState.failing => '$failed failed',
      ChecksState.pending => '$pending running',
      ChecksState.passing || ChecksState.none => '$total passed',
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ChecksSummary &&
      other.passed == passed &&
      other.failed == failed &&
      other.pending == pending &&
      other.skipped == skipped;

  @override
  int get hashCode => Object.hash(passed, failed, pending, skipped);

  @override
  String toString() =>
      'ChecksSummary(${state.name}: $passed ok, $failed failed, '
      '$pending running, $skipped skipped)';
}

/// Everything one `gh pr view` call knows about the pull request for a branch.
///
/// One object from one process: the PR and its checks are drawn side by side, so
/// splitting them would double the `gh` invocations.
class PullRequestSnapshot {
  const PullRequestSnapshot({
    required this.number,
    required this.state,
    this.title = '',
    this.url,
    this.isDraft = false,
    this.mergeable,
    this.mergeStateStatus,
    this.reviewDecision,
    this.unresolvedReviewThreads,
    this.checks = ChecksSummary.none,
    this.headRefName,
    this.baseRefName,
  });

  final int number;
  final PullRequestState state;
  final String title;
  final String? url;
  final bool isDraft;

  /// Whether GitHub says the branch merges cleanly. Null is GitHub's own
  /// `UNKNOWN` — it computes this asynchronously and has not finished.
  final bool? mergeable;

  /// GitHub's own verdict on why this cannot merge. See [MergeStateStatus] for
  /// why only positive readings of it are ever trusted.
  final MergeStateStatus? mergeStateStatus;

  final ReviewDecision? reviewDecision;

  /// How many review conversations are still open on this pull request.
  ///
  /// **Null is "we did not ask", and that is the normal case**: review threads
  /// and their resolved flags are not in `gh pr view`'s JSON field set, so this
  /// costs a second GraphQL process only the session strip pays for. Zero means
  /// asked, and every conversation resolved.
  final int? unresolvedReviewThreads;

  final ChecksSummary checks;
  final String? headRefName;

  /// The branch this one would merge *into*. What branch protection applies
  /// to, and so what a `BLOCKED` merge's rule has to be read for.
  final String? baseRefName;

  bool get isOpen => state == PullRequestState.open;

  /// Whether something established says this branch and its base disagree.
  ///
  /// Either reading alone is enough: `mergeable: CONFLICTING` and
  /// `mergeStateStatus: DIRTY` come from one computation but two fields. Null on
  /// both stays not-a-conflict — a claimed conflict sends an agent to fix nothing.
  bool get hasConflict =>
      mergeable == false || mergeStateStatus == MergeStateStatus.dirty;

  /// Whether GitHub itself says the base has moved on under this branch.
  ///
  /// Only the positive reading, and not the whole answer: this field is masked
  /// whenever a higher-priority blocker also applies. See
  /// `SessionDelivery.isBehindBase`.
  bool get isBehindBase => mergeStateStatus == MergeStateStatus.behind;

  /// Whether a human is waiting on a change to this branch.
  bool get wantsChanges => reviewDecision == ReviewDecision.changesRequested;

  /// Whether review conversations are open, on a reading we actually took.
  bool get hasUnresolvedReviewComments => (unresolvedReviewThreads ?? 0) > 0;

  /// Whether this is ready for a human to press merge: open, not a draft, no
  /// failing or running checks, no requested changes, and GitHub says it merges.
  bool get isReadyToMerge =>
      isOpen &&
      !isDraft &&
      mergeable == true &&
      reviewDecision != ReviewDecision.changesRequested &&
      (checks.state == ChecksState.passing || checks.state == ChecksState.none);

  /// This snapshot with its review-thread count filled in.
  ///
  /// A single-field copier rather than a general `copyWith`: this is the only
  /// field that arrives from a different process, and a general one would invite
  /// synthesising pull request state no `gh` call reported.
  PullRequestSnapshot withUnresolvedReviewThreads(int? count) =>
      PullRequestSnapshot(
        number: number,
        state: state,
        title: title,
        url: url,
        isDraft: isDraft,
        mergeable: mergeable,
        mergeStateStatus: mergeStateStatus,
        reviewDecision: reviewDecision,
        unresolvedReviewThreads: count,
        checks: checks,
        headRefName: headRefName,
        baseRefName: baseRefName,
      );

  @override
  bool operator ==(Object other) =>
      other is PullRequestSnapshot &&
      other.number == number &&
      other.state == state &&
      other.title == title &&
      other.url == url &&
      other.isDraft == isDraft &&
      other.mergeable == mergeable &&
      other.mergeStateStatus == mergeStateStatus &&
      other.reviewDecision == reviewDecision &&
      other.unresolvedReviewThreads == unresolvedReviewThreads &&
      other.checks == checks &&
      other.headRefName == headRefName &&
      other.baseRefName == baseRefName;

  @override
  int get hashCode => Object.hash(
    number,
    state,
    title,
    url,
    isDraft,
    mergeable,
    mergeStateStatus,
    reviewDecision,
    unresolvedReviewThreads,
    checks,
    headRefName,
    baseRefName,
  );

  @override
  String toString() => 'PullRequestSnapshot(#$number ${state.name})';
}
