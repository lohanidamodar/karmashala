import 'repository.dart';

/// A checkout whose directory is gone but whose row is not, because deleting
/// the row would take [records] rows of recorded history down with it.
///
/// Every foreign key pointing at `repositories` is `ON DELETE CASCADE`, so
/// tidying a stale checkout away is a silent deletion of the user's session
/// history, performed by a rescan they asked for a different reason.
class ReferencedCheckout {
  const ReferencedCheckout({required this.repository, required this.records});

  final Repository repository;

  /// How many rows of history a delete would have destroyed. Carried so the
  /// message can say *what* is at stake rather than just "could not remove".
  final int records;

  @override
  bool operator ==(Object other) =>
      other is ReferencedCheckout &&
      other.repository == repository &&
      other.records == records;

  @override
  int get hashCode => Object.hash(repository, records);

  @override
  String toString() => 'ReferencedCheckout(${repository.name}, $records)';
}

/// What a rescan's retirement pass did with one project's recorded checkouts.
///
/// A report rather than a count because every outcome may need telling: rows for
/// worktrees deleted from disk cost six `git` subprocesses per refresh, a
/// checkout that only *looks* gone because a distro is stopped must survive, and
/// one that is gone but carries history must survive **and be named**.
class CheckoutRetirementReport {
  const CheckoutRetirementReport({
    required this.examined,
    this.rootReachable = true,
    this.retired = const [],
    this.keptReferenced = const [],
    this.keptUnreachable = const [],
  });

  /// A pass that found nothing of its own to consider.
  static const nothing = CheckoutRetirementReport(examined: 0);

  /// How many of the project's recorded checkouts were candidates — those under
  /// the root being rescanned. Distinguishes "checked, all fine" from
  /// "there was nothing here to check".
  final int examined;

  /// Whether the project root itself could be found. When it could not, nothing
  /// beneath it is judged: an unmounted drive makes every child read as absent.
  final bool rootReachable;

  /// Rows deleted: provably absent on a filesystem that answered, with no
  /// history hanging off them.
  final List<Repository> retired;

  /// Provably absent, but kept because deleting them would cascade. The list
  /// the user actually needs to see.
  final List<ReferencedCheckout> keptReferenced;

  /// Kept because we could not tell. Not a problem to fix — a partial answer to
  /// report, so "nothing was retired" does not read as "everything is fine".
  final List<Repository> keptUnreachable;

  /// Whether any row was actually removed. The trigger for a refresh.
  bool get hasChanges => retired.isNotEmpty;

  /// Whether the pass has anything at all worth saying.
  bool get isEmpty =>
      retired.isEmpty && keptReferenced.isEmpty && keptUnreachable.isEmpty;

  @override
  String toString() =>
      'CheckoutRetirementReport(examined: $examined, '
      'retired: ${retired.length}, referenced: ${keptReferenced.length}, '
      'unreachable: ${keptUnreachable.length}, root: $rootReachable)';
}
