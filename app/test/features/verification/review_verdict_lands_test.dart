import 'dart:io';

import 'package:karmashala/src/features/fanout/application/comparison_providers.dart';
import 'package:karmashala/src/features/fanout/application/fanout_service.dart';
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala/src/features/verification/application/review_session_service.dart';
import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/verification/data/verification_data.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../fanout/fanout_harness.dart';

/// The claim the whole feature rests on: a review session's verdict reaches the
/// fan-out comparison **through the plumbing step 1 already built**, with no
/// new column, no new link kind and no new lookup.
///
/// So this is deliberately end to end — a real fan-out, a real review launch,
/// and the run the reviewer's verification_* calls leave (recorded by the
/// server since slice 4a) — rather than three unit tests that each assume the
/// seam they do not cross.
void main() {
  late Harness h;
  late Directory root;
  late VerificationService verification;

  setUp(() async {
    h = await connectedHarness();
    root = Directory.systemTemp.createTempSync('review-verdict');
    verification = VerificationService(
      VerificationData(h.container.read(dataClientProvider)),
      VerificationArtifactStore(root),
    );
  });

  /// A finished review of the change, as the server records one.
  Future<void> recordReview({
    required String subject,
    required String reviewer,
    required String title,
    required String reason,
  }) async {
    final at = DateTime.now().toUtc();
    await VerificationData(h.container.read(dataClientProvider)).record(
      VerificationRun(
        id: 'review-${at.microsecondsSinceEpoch}',
        title: title,
        target: const VerificationTarget.change(),
        sessionId: subject,
        producedBySessionId: reviewer,
        startedAt: at,
        finishedAt: at,
        verdict: VerificationVerdict.pass,
        reason: reason,
        artifactDirectory: root.path,
      ),
    );
  }

  tearDown(() async {
    await verification.dispose();
    h.container.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'a review session\'s verdict lands on the candidate as independent',
    () async {
      final launch = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall],
            prompt: 'Make the parser accept trailing commas.',
          );
      final subject = launch.started.first;

      // One click: the other installed agent is asked to check this candidate.
      final review = await h.container
          .read(reviewSessionServiceProvider)
          .startReview(
            sessionId: subject.session.id,
            targetInstallationId: secondRoverInstall.id,
            claim: launch.comparison.prompt,
          );

      // What the reviewer's verification_* calls leave: a finished change
      // run the server recorded (slice 4a: it records every run).
      await recordReview(
        subject: subject.session.id,
        reviewer: review.session.id,
        title: 'Review of the trailing-comma fix',
        reason: 'Nothing wrong found; the two new tests cover the case.',
      );

      final candidate = launch.comparison.candidates.firstWhere(
        (c) => c.sessionId == subject.session.id,
      );
      final lookup = h.container.read(candidateEvidenceProvider);
      final evidence = evidenceShownFor(candidate, lookup)!;

      expect(evidence.verdict, EvidenceVerdict.passed);
      expect(evidence.producerSessionId, review.session.id);
      expect(
        attributionShownFor(candidate, lookup),
        VerdictAttribution.independent,
      );
    },
  );

  test('a review that finds nothing is still a recorded verdict', () async {
    final launch = await h.container
        .read(fanOutServiceProvider)
        .launch(
          repository: repository(),
          installations: [roverInstall, flakyInstall],
          prompt: 'Make the parser accept trailing commas.',
        );
    final subject = launch.started.first;
    final review = await h.container
        .read(reviewSessionServiceProvider)
        .startReview(
          sessionId: subject.session.id,
          targetInstallationId: secondRoverInstall.id,
        );
    await recordReview(
      subject: subject.session.id,
      reviewer: review.session.id,
      title: 'Review of the change',
      reason: 'Read the whole diff and found nothing to raise.',
    );

    // The record exists, is attached to the work, and says who signed it —
    // "nothing found" as a fact rather than as an absence.
    final runs = await verification.list(sessionId: subject.session.id);
    expect(runs, hasLength(1));
    expect(runs.single.reason, contains('found nothing'));
    expect(runs.single.attribution, VerdictAttribution.independent);
  });
}
