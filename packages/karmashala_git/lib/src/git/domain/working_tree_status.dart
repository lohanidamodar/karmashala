import 'file_change.dart';

/// What one `git status --porcelain=v2 --branch` says: the branch, its
/// upstream, how far they have diverged, and the changed files.
///
/// One type because git answers all of it in **one process**; asking separately
/// is four processes per checkout for data one already carried.
class WorkingTreeStatus {
  const WorkingTreeStatus({
    this.branch,
    this.upstream,
    this.aheadOfUpstream,
    this.behindUpstream,
    this.changes = const [],
  });

  static const unknown = WorkingTreeStatus();

  /// The checked-out branch; null when detached.
  final String? branch;

  /// The tracking branch (`origin/work`); null when the branch has none.
  final String? upstream;

  /// Commits the branch has that its upstream does not. **Null is "could not
  /// tell" and never zero** — git omits `# branch.ab` when there is no upstream
  /// or it has gone from the remote; level with one is `+0 -0`, said out loud.
  final int? aheadOfUpstream;

  final int? behindUpstream;

  final List<FileChange> changes;

  bool get isDirty => changes.isNotEmpty;

  @override
  String toString() =>
      'WorkingTreeStatus($branch -> $upstream, +$aheadOfUpstream '
      '-$behindUpstream, ${changes.length} changed)';
}
