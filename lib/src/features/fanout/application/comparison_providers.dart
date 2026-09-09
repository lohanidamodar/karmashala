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

/// Looks up a verification verdict for a candidate's session.
///
/// **The seam for Loop 51's `features/verification/`**, now filled by it. The
/// dependency runs one way — fan-out reads verification, verification knows
/// nothing about comparisons — and the type crossing it is fan-out's own
/// [CandidateEvidence], so a run can be pruned without taking a comparison's
/// verdict with it. The column still falls back to the copy stored on the
/// candidate, which is all that survives that pruning.
///
/// Reads the **DAO**, not the service: a verdict is one row, and the service
/// resolves an artifact directory that a comparison has no use for and that
/// would have to exist before this column could paint. The lookup runs on each
/// rebuild rather than pushing, because a comparison column is rebuilt whenever
/// anything about the candidate changes and a run finishing while one is on
/// screen is not the case worth a stream for.
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

/// The evidence a surface should show for [candidate]: the live run when one
/// offers a verdict, otherwise the copy frozen into the comparison — which is
/// all that is left once the run is pruned.
///
/// One function, because the candidate's chip, the comparison's outcome and
/// the merge confirmation all answer "who graded this" and must not answer it
/// differently. Two of them resolving the evidence separately is how the list
/// comes to say `self` while the dialog beside it says `independent`.
CandidateEvidence? evidenceShownFor(
  ComparisonCandidate candidate,
  CandidateEvidenceLookup lookup,
) {
  final sessionId = candidate.sessionId;
  return (sessionId == null ? null : lookup(sessionId)) ?? candidate.evidence;
}

/// [evidenceShownFor], reduced to the one fact every verdict surface states.
///
/// Falls back to [VerdictAttribution.notRecorded] rather than to null: a
/// candidate nobody verified and a verdict nobody signed are the same answer
/// to "was this checked by someone else", and a surface that renders nothing
/// for either reads as "verified" to anyone scanning it.
VerdictAttribution attributionShownFor(
  ComparisonCandidate candidate,
  CandidateEvidenceLookup lookup,
) =>
    evidenceShownFor(
      candidate,
      lookup,
    )?.attributionFor(candidate.sessionId) ??
    VerdictAttribution.notRecorded;

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
