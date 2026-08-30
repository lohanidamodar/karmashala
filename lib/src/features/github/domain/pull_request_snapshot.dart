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
/// Deliberately one object from one process: the PR and its checks are drawn
/// side by side and asked for together, so splitting them would double the
/// `gh` invocations for a surface that shows them in the same row.
class PullRequestSnapshot {
  const PullRequestSnapshot({
    required this.number,
    required this.state,
    this.title = '',
    this.url,
    this.isDraft = false,
    this.mergeable,
    this.reviewDecision,
    this.checks = ChecksSummary.none,
    this.headRefName,
  });

  final int number;
  final PullRequestState state;
  final String title;
  final String? url;
  final bool isDraft;

  /// Whether GitHub says the branch merges cleanly. Null is GitHub's own
  /// `UNKNOWN` — it computes this asynchronously and has not finished.
  final bool? mergeable;

  final ReviewDecision? reviewDecision;
  final ChecksSummary checks;
  final String? headRefName;

  bool get isOpen => state == PullRequestState.open;

  /// Whether this is ready for a human to press merge: open, not a draft, no
  /// failing or running checks, no requested changes, and GitHub says it merges.
  bool get isReadyToMerge =>
      isOpen &&
      !isDraft &&
      mergeable == true &&
      reviewDecision != ReviewDecision.changesRequested &&
      (checks.state == ChecksState.passing || checks.state == ChecksState.none);

  @override
  bool operator ==(Object other) =>
      other is PullRequestSnapshot &&
      other.number == number &&
      other.state == state &&
      other.title == title &&
      other.url == url &&
      other.isDraft == isDraft &&
      other.mergeable == mergeable &&
      other.reviewDecision == reviewDecision &&
      other.checks == checks &&
      other.headRefName == headRefName;

  @override
  int get hashCode => Object.hash(
    number,
    state,
    title,
    url,
    isDraft,
    mergeable,
    reviewDecision,
    checks,
    headRefName,
  );

  @override
  String toString() => 'PullRequestSnapshot(#$number ${state.name})';
}
