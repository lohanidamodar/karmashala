/// Which merge buttons a repository's settings actually leave enabled.
///
/// From `gh`'s GraphQL `repository { mergeCommitAllowed squashMergeAllowed
/// rebaseMergeAllowed }`, so the strip never offers a merge the forge would
/// refuse: a squash-only repository rejects `gh pr merge --merge` outright.
///
/// **Every field is nullable and null means "could not tell"**: [unknown] must
/// behave exactly as the code did before this type existed — offer the merge and
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
  /// Requires all three to be a definite `false`. GitHub's settings UI refuses to
  /// let you turn the last one off, so this is for a policy arriving anyway.
  bool get noneAllowed =>
      mergeCommit == false && squash == false && rebase == false;

  /// The strategy to name in the merge prompt, or null when we should not name
  /// one at all.
  ///
  /// **Merge commit, then squash, then rebase** — not a quality ranking, the
  /// order that loses the least information. Null when nothing was established,
  /// which leaves the prompt as it read before, so `gh` picks the repository's own.
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
