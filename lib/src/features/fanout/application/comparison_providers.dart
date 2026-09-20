import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../verification/application/verification_providers.dart';
import '../../verification/domain/verdict_attribution.dart';
import '../../verification/domain/verification_run.dart';
import '../data/comparison_dao.dart';
import '../domain/comparison.dart';

/// Provides the [ComparisonDao].
final comparisonDaoProvider = Provider<ComparisonDao>(
  (ref) => ComparisonDao(ref.watch(databaseProvider)),
);

/// Looks up a verification verdict for a candidate's session. Reads the DAO,
/// not the service, and the column falls back to the copy on the candidate.
typedef CandidateEvidenceLookup = CandidateEvidence? Function(String sessionId);

final candidateEvidenceProvider = Provider<CandidateEvidenceLookup>((ref) {
  final dao = ref.watch(verificationDaoProvider);
  return (sessionId) {
    // Newest first; the newest run that reached a verdict is the answer. An
    // open run is not evidence of anything yet.
    for (final run in dao.listRuns(sessionId: sessionId)) {
      final verdict = run.verdict;
      if (verdict == null) continue;
      final reason = run.reason?.trim();
      return CandidateEvidence(
        verdict: switch (verdict) {
          VerificationVerdict.pass => EvidenceVerdict.passed,
          VerificationVerdict.fail => EvidenceVerdict.failed,
          VerificationVerdict.inconclusive => EvidenceVerdict.inconclusive,
        },
        label: reason == null || reason.isEmpty ? run.title : reason,
        runId: run.id,
        producerSessionId: run.producedBySessionId,
      );
    }
    return null;
  };
});

/// The evidence a surface should show for [candidate]: the live run, else the
/// frozen copy. One function, so the chip and the dialog cannot disagree.
CandidateEvidence? evidenceShownFor(
  ComparisonCandidate candidate,
  CandidateEvidenceLookup lookup,
) {
  final sessionId = candidate.sessionId;
  return (sessionId == null ? null : lookup(sessionId)) ?? candidate.evidence;
}

/// [evidenceShownFor] reduced to the one fact every verdict surface states.
/// Falls back to `notRecorded`, because rendering nothing reads as "verified".
VerdictAttribution attributionShownFor(
  ComparisonCandidate candidate,
  CandidateEvidenceLookup lookup,
) =>
    evidenceShownFor(candidate, lookup)?.attributionFor(candidate.sessionId) ??
    VerdictAttribution.notRecorded;

/// The comparisons list, and the one operation on it that is not a fan-out.
/// A `Notifier`, because every mutation goes through [FanOutService].
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
