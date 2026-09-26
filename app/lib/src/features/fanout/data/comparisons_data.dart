import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The fan-out comparisons as the server keeps them: read at once from this
/// app's copy, newest first; every write goes to the server, which answers
/// the comparison whole.
class ComparisonsData {
  ComparisonsData(this._client);

  final DataClient _client;

  /// Fires after any comparison changed — here or at another client.
  Stream<void> get changes => _client.comparisons.changes;

  Comparison? getById(String id) => _client.comparisons[id];

  /// Newest first; [repositoryId] narrows to one checkout, archived ones only
  /// when [includeArchived].
  List<Comparison> getAll({
    String? repositoryId,
    bool includeArchived = false,
  }) => [
    for (final c in _client.comparisons.values)
      if ((repositoryId == null || c.repositoryId == repositoryId) &&
          (includeArchived || !c.archived))
        c,
  ]..sort(compareComparisons);

  Future<Comparison> create(Comparison comparison) =>
      _write(ComparisonCreate(comparison));

  Future<Comparison> recordDiff(String candidateId, CandidateDiffStat diff) =>
      _write(ComparisonRecordDiff(candidateId, diff));

  Future<Comparison> worktreeRemoved(String candidateId) =>
      _write(ComparisonWorktreeRemoved(candidateId));

  Future<Comparison> setWinner(String id, String? candidateId) =>
      _write(ComparisonSetWinner(id, candidateId));

  /// Ends [id] merged or discarded; the server stamps when.
  Future<Comparison> close(
    String id, {
    required ComparisonOutcome outcome,
    String? winnerCandidateId,
    String? mergedCommit,
  }) => _write(
    ComparisonClose(
      id,
      outcome: outcome,
      winnerCandidateId: winnerCandidateId,
      mergedCommit: mergedCommit,
    ),
  );

  /// Put away (or back) at once in the copy, and at the server after.
  Future<Comparison> archive(String id, {required bool archived}) {
    final comparison = _client.comparisons[id];
    if (comparison != null) {
      _client.comparisons.setLocal(id, comparison.copyWith(archived: archived));
    }
    return _write(ComparisonArchive(id, archived: archived));
  }

  Future<R> _write<R>(DataRequest<R> request) =>
      _client.write(request, domain: DataDomain.evidence);
}

final comparisonsDataProvider = Provider<ComparisonsData>(
  (ref) => ComparisonsData(ref.watch(dataClientProvider)),
);
