import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../automations/application/automation_check_runner.dart';
import '../../verification/application/verification_providers.dart';
import 'package:karmashala_verification/verification.dart';
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
  // A new run is a new answer: without this a column kept its old verdict
  // until something else rebuilt it.
  ref.watch(verificationRevisionProvider);
  final dao = ref.watch(verificationDaoProvider);
  return (sessionId) {
    // Newest first. An open run is not evidence of anything yet, and — as on
    // the strip (`SessionVerdict.of`) — the newest verdict someone other than
    // the author produced wins over any newer one the candidate gave itself.
    final finished = [
      for (final run in dao.listRuns(sessionId: sessionId))
        if (run.verdict != null) run,
    ];
    final chosen =
        finished.where((run) => run.attribution.isIndependent).firstOrNull ??
        finished.firstOrNull;
    if (chosen == null) return null;
    final reason = chosen.reason?.trim();
    return CandidateEvidence(
      verdict: switch (chosen.verdict!) {
        VerificationVerdict.pass => EvidenceVerdict.passed,
        VerificationVerdict.fail => EvidenceVerdict.failed,
        VerificationVerdict.inconclusive => EvidenceVerdict.inconclusive,
      },
      label: reason == null || reason.isEmpty ? chosen.title : reason,
      runId: chosen.id,
      producerSessionId: chosen.producedBySessionId,
    );
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

/// Runs the repository's project checks in every candidate that still has a
/// worktree and a session, **at once** — each is its own worktree, which is
/// what makes them safe to run side by side. Each batch lands as that
/// candidate's newest verification run, so the column's verdict is it.
///
/// Answers how many candidates were checked; zero when the repository has no
/// checks configured.
Future<int> runCandidateChecks(
  Future<SessionChecks?> Function(String sessionId) runForSession,
  Comparison comparison,
) async {
  final sessions = [
    for (final candidate in comparison.candidates)
      if (candidate.hasLiveWorktree && candidate.sessionId != null)
        candidate.sessionId!,
  ];
  final results = await Future.wait(sessions.map(runForSession));
  return results.nonNulls.length;
}

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
