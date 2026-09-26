import 'dart:async';

import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_core/logging.dart';
import 'package:riverpod/riverpod.dart';

import '../../automations/application/automation_check_runner.dart';
import '../../verification/application/verification_providers.dart';
import '../../verification/data/verification_data.dart';
import 'package:karmashala_verification/verification.dart';
import '../data/comparisons_data.dart';

/// Looks up a verification verdict for a candidate's session. Reads the copied
/// run headers, not the service; the column falls back to the candidate's own.
typedef CandidateEvidenceLookup = CandidateEvidence? Function(String sessionId);

final candidateEvidenceProvider = Provider<CandidateEvidenceLookup>((ref) {
  // A new run is a new answer: without this a column kept its old verdict
  // until something else rebuilt it.
  ref.watch(verificationRevisionProvider);
  final runs = ref.watch(verificationDataProvider);
  return (sessionId) {
    // Newest first. An open run is not evidence of anything yet, and — as on
    // the strip (`SessionVerdict.of`) — the newest verdict someone other than
    // the author produced wins over any newer one the candidate gave itself.
    final finished = [
      for (final run in runs.headersOf(sessionId))
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

/// The comparisons list, from this app's copy, and the one operation on it
/// that is not a fan-out. Follows every change, here or at another client.
class ComparisonsController extends Notifier<List<Comparison>> {
  static final _log = AppLogger.named('fanout');

  @override
  List<Comparison> build() {
    final listening = ref
        .watch(comparisonsDataProvider)
        .changes
        .listen((_) => state = _read());
    ref.onDispose(listening.cancel);
    return _read();
  }

  List<Comparison> _read() => ref
      .read(comparisonsDataProvider)
      .getAll(includeArchived: includeArchived);

  /// Whether archived comparisons are in [state]. Off by default: an archived
  /// comparison is one the user has finished with.
  bool includeArchived = false;

  void reload() => state = _read();

  void showArchived(bool value) {
    includeArchived = value;
    reload();
  }

  void archive(String comparisonId, {bool archived = true}) => unawaited(
    ref
        .read(comparisonsDataProvider)
        .archive(comparisonId, archived: archived)
        .then<void>(
          (_) {},
          onError: (Object error) => _log.warning('Not archived: $error'),
        ),
  );
}

final comparisonsProvider =
    NotifierProvider<ComparisonsController, List<Comparison>>(
      ComparisonsController.new,
    );

/// One comparison, from the copy. Returns `null` once it is gone.
final comparisonProvider = Provider.family<Comparison?, String>((ref, id) {
  ref.watch(comparisonsProvider);
  return ref.read(comparisonsDataProvider).getById(id);
});
