/// How far a session's work has travelled: working → committed → pushed →
/// pr-open → checks → merged → archived. The *furthest* point, not the next.
enum DeliveryStage {
  /// Uncommitted work, or no work yet.
  working(order: 0, label: 'Working'),

  /// Commits that no remote has.
  committed(order: 1, label: 'Committed'),

  /// The branch is on the remote, with nothing proposed yet.
  pushed(order: 2, label: 'Pushed'),

  /// A pull request is open; its checks have not said anything yet.
  prOpen(order: 3, label: 'PR open'),

  /// A check failed. Shares [order] with [checksPassing]: a red build is not
  /// *behind* a green one, it is the same distance with a different answer.
  checksFailing(order: 4, label: 'Checks failing'),

  checksPassing(order: 4, label: 'Checks passing'),

  merged(order: 5, label: 'Merged'),

  /// The worktree has been removed. The transcript, review notes and
  /// checkpoints are all still there — see `SessionArchiveService`.
  archived(order: 6, label: 'Archived');

  const DeliveryStage({required this.order, required this.label});

  /// How far along the line this is, for anything drawing progress. Not an
  /// index into [values]: two stages deliberately share a position.
  final int order;

  final String label;

  /// Whether this stage is one the user should look at rather than act on.
  bool get isTrouble => this == DeliveryStage.checksFailing;

  /// Whether the work has left the machine.
  bool get isPublished => order >= DeliveryStage.pushed.order;
}
