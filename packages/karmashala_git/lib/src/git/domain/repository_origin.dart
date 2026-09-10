/// What a clone records about `origin`: where it points, and which branch it
/// calls the default.
///
/// **Both are properties of the repository, not of a working tree** — they live
/// in the clone's git directory, so every worktree of one clone shares one answer,
/// and asking per checkout asks the same files once per row.
class RepositoryOrigin {
  const RepositoryOrigin({this.url, this.head});

  /// A repository with no `origin` at all — and the answer for a directory
  /// that is not a repository, which is a row with nothing to say rather than
  /// an error.
  static const none = RepositoryOrigin();

  /// `origin`'s URL, or null when there is no `origin` remote.
  final String? url;

  /// The default branch as this clone recorded it (`origin/main`), or null when
  /// `origin/HEAD` is not set — which a single-branch clone and an older `git
  /// remote add` both produce.
  final String? head;

  bool get hasRemote => url != null;

  /// `origin/main` → `main`. What `gh repo view` would call the default branch,
  /// without asking it.
  String? get defaultBranch {
    final ref = head;
    if (ref == null) return null;
    final slash = ref.indexOf('/');
    return slash < 0 ? ref : ref.substring(slash + 1);
  }

  @override
  bool operator ==(Object other) =>
      other is RepositoryOrigin && other.url == url && other.head == head;

  @override
  int get hashCode => Object.hash(url, head);

  @override
  String toString() => 'RepositoryOrigin($url, head: $head)';
}
