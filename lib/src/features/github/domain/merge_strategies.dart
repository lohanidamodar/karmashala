/// Which merge buttons a repository's settings actually leave enabled.
///
/// From `gh`'s GraphQL `repository { mergeCommitAllowed squashMergeAllowed
/// rebaseMergeAllowed }` — verified against `cli/cli` and this repository on
/// 2026-09-02.
///
/// **This exists so the strip never offers a merge the forge would refuse.** A
/// great many repositories turn two of the three off; a squash-only repository
/// rejects `gh pr merge --merge` outright, and a merge-commit-only repository
/// rejects `--squash`. Sending an agent a prompt that names a forbidden
/// strategy costs a round trip and a confusing error in the transcript, and
/// worse, teaches the user that the button lies.
///
/// **Every field is nullable and null means "could not tell"**, the same rule
/// `SessionDelivery` sets, because the query behind them is a second `gh`
/// process that is skipped for rows nobody is looking at and fails for all the
/// ordinary reasons (`gh` logged out, a non-GitHub remote, a repository the
/// token cannot read settings for). [unknown] — everything null — must behave
/// exactly like today's code did before this type existed: offer the merge and
/// let the forge answer.
class MergeStrategies {
  const MergeStrategies({this.mergeCommit, this.squash, this.rebase});

  /// Nothing asked, or nothing answered.
  static const unknown = MergeStrategies();

  final bool? mergeCommit;
  final bool? squash;
  final bool? rebase;

  /// Whether we positively established that **no** strategy is available.
  ///
  /// Requires all three to be a definite `false`. A repository cannot really be
  /// in this state through the settings UI — GitHub refuses to let you turn the
  /// last one off — so this is here for the case where it arrives anyway
  /// (an enterprise policy, a future setting) rather than as an expected state.
  /// The point is that a strip which cannot name a legal merge should say so
  /// instead of offering one.
  bool get noneAllowed =>
      mergeCommit == false && squash == false && rebase == false;

  /// The strategy to name in the merge prompt, or null when we should not name
  /// one at all.
  ///
  /// **Merge commit first, then squash, then rebase.** Not a quality ranking:
  /// it is the order that loses the least information. A merge commit keeps
  /// every commit and the shape of the branch; a squash discards the branch's
  /// internal history; a rebase discards the fact that a branch existed. When
  /// the repository allows several, the agent — and the human reading the
  /// transcript — can still choose differently, because a named strategy in a
  /// one-sentence prompt is a default, not an instruction the model cannot
  /// override.
  ///
  /// Null when nothing was established, and that is the important case: an
  /// unnamed strategy leaves the prompt exactly as it read before this feature
  /// ("Merge the pull request."), so `gh` picks the repository's own default.
  /// Guessing a name would be strictly worse than saying nothing.
  String? get preferredLabel {
    if (mergeCommit == true) return 'merge commit';
    if (squash == true) return 'squash merge';
    if (rebase == true) return 'rebase merge';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is MergeStrategies &&
      other.mergeCommit == mergeCommit &&
      other.squash == squash &&
      other.rebase == rebase;

  @override
  int get hashCode => Object.hash(mergeCommit, squash, rebase);

  @override
  String toString() =>
      'MergeStrategies(merge $mergeCommit, squash $squash, rebase $rebase)';
}
