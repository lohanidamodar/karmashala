import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/comparison_dao.dart';
import '../domain/comparison.dart';

/// Provides the [ComparisonDao].
final comparisonDaoProvider = Provider<ComparisonDao>(
  (ref) => ComparisonDao(ref.watch(databaseProvider)),
);

/// Looks up a verification verdict for a candidate's session.
///
/// **The seam for Loop 51's `features/verification/`.** Fan-out will not depend
/// on that feature — it shows a verdict when something offers one, and shows
/// nothing when nothing does. Verification overrides this provider in one line;
/// until it exists, every candidate answers `null` and the column simply has no
/// verdict row.
typedef CandidateEvidenceLookup = CandidateEvidence? Function(String sessionId);

final candidateEvidenceProvider = Provider<CandidateEvidenceLookup>(
  (ref) =>
      (_) => null,
);

/// The comparisons list, and the one operation the UI performs on it that is
/// not a fan-out: reload after something changed underneath.
///
/// A `Notifier` rather than a `FutureProvider` because every mutation happens
/// through [FanOutService] and the view has to be told; invalidation from four
/// call sites would be the alternative.
class ComparisonsController extends Notifier<List<Comparison>> {
  @override
  List<Comparison> build() => _read();

  List<Comparison> _read() =>
      ref.read(comparisonDaoProvider).getAll(includeArchived: includeArchived);

  /// Whether archived comparisons are in [state]. Off by default: an archived
  /// comparison is one the user has finished with.
  bool includeArchived = false;

  void reload() => state = _read();

  void showArchived(bool value) {
    includeArchived = value;
    reload();
  }

  void archive(String comparisonId, {bool archived = true}) {
    ref.read(comparisonDaoProvider).setArchived(comparisonId, archived);
    reload();
  }
}

final comparisonsProvider =
    NotifierProvider<ComparisonsController, List<Comparison>>(
      ComparisonsController.new,
    );

/// One comparison, re-read from the database. Returns `null` once it is gone.
final comparisonProvider = Provider.family<Comparison?, String>((ref, id) {
  ref.watch(comparisonsProvider);
  return ref.read(comparisonDaoProvider).getById(id);
});
