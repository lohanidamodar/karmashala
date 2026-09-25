import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/fanout/application/comparison_providers.dart';
import 'package:karmashala/src/features/fanout/data/comparison_dao.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_list.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_view.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/verification/domain/verdict_attribution.dart';
import 'package:karmashala/src/features/verification/presentation/attribution_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import 'comparison_fixtures.dart';

/// A comparison's *outcome* is a verdict being acted on.
///
/// `ComparisonOutcome.merged` is reached by trusting a candidate's evidence,
/// and until now the outcome said "merged" whether that evidence was the
/// candidate's own account of itself or an independent check. Nothing here
/// blocks a merge — G3 step 2 is where policy changes — it only makes the fact
/// legible at the two places the decision is read and made.
void main() {
  ComparisonCandidate winnerWith(String? producerSessionId) =>
      ComparisonCandidate(
        id: 'cand-win',
        comparisonId: 'cmp-1',
        position: 0,
        installationId: 'a1',
        agentId: 'claudeCode',
        launch: CandidateLaunchState.started,
        sessionId: 's-win',
        evidence: CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          label: '12 tests, 0 failed',
          producerSessionId: producerSessionId,
        ),
      );

  group('one resolver answers who graded a candidate', () {
    /// A stand-in for the live lookup, so the fallback chain is what is under
    /// test rather than the DAO underneath it.
    CandidateEvidenceLookup lookup([
      Map<String, CandidateEvidence> live = const {},
    ]) =>
        (sessionId) => live[sessionId];

    test('a live run outranks the copy frozen into the comparison', () {
      // The stored copy is a snapshot; a run that finished afterwards is the
      // current answer, and it brings its own producer with it.
      final candidate = winnerWith('s-win');
      final resolved = attributionShownFor(
        candidate,
        lookup({
          's-win': const CandidateEvidence(
            verdict: EvidenceVerdict.passed,
            label: 'checked again',
            producerSessionId: 's-other',
          ),
        }),
      );

      expect(resolved, VerdictAttribution.independent);
    });

    test('the frozen copy answers once the run behind it is gone', () {
      expect(
        attributionShownFor(winnerWith('s-win'), lookup()),
        VerdictAttribution.author,
      );
    });

    test('a verdict naming no producer reads as not recorded', () {
      expect(
        attributionShownFor(winnerWith(null), lookup()),
        VerdictAttribution.notRecorded,
      );
    });

    test('a candidate with no evidence at all is answered, not skipped', () {
      // The robustness bar: unknown attribution must resolve to a state that
      // renders, never to null that a surface then draws as nothing.
      const bare = ComparisonCandidate(
        id: 'cand-win',
        comparisonId: 'cmp-1',
        position: 0,
        installationId: 'a1',
        agentId: 'claudeCode',
        launch: CandidateLaunchState.started,
        sessionId: 's-win',
      );

      expect(evidenceShownFor(bare, lookup()), isNull);
      expect(
        attributionShownFor(bare, lookup()),
        VerdictAttribution.notRecorded,
      );
    });

    test(
      'a candidate that never started has no session to compare against',
      () {
        const never = ComparisonCandidate(
          id: 'cand-dead',
          comparisonId: 'cmp-1',
          position: 2,
          installationId: 'a3',
          agentId: 'flakyCli',
          launch: CandidateLaunchState.failed,
        );

        expect(
          attributionShownFor(never, lookup()),
          VerdictAttribution.notRecorded,
        );
      },
    );
  });

  group('the outcome carries it on screen', () {
    Future<void> pumpList(WidgetTester tester, AppDatabase db) =>
        tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: MaterialApp(
              home: Scaffold(
                body: ComparisonList(onOpen: (_) {}, onNew: () {}),
              ),
            ),
          ),
        );

    /// Rewrites the winner's producer, which is the only thing under test.
    AppDatabase seedWithProducer(String? producerSessionId) {
      final db = seedDatabase();
      ComparisonDao(db).updateEvidence(
        'cand-win',
        CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          label: '12 tests, 0 failed',
          producerSessionId: producerSessionId,
        ),
      );
      return db;
    }

    testWidgets('the list says a merge rested on a self-graded verdict', (
      tester,
    ) async {
      final db = seedWithProducer('s-win');
      addTearDown(db.close);

      await pumpList(tester, db);

      // The list is the only place a merged comparison is seen without also
      // seeing a candidate's verdict chip, so the mark has to travel with the
      // outcome itself.
      expect(find.textContaining('merged abc1234'), findsOneWidget);
      expect(find.byType(AttributionMark), findsOneWidget);
      expect(find.text('self'), findsOneWidget);
    });

    testWidgets('a merge on an unattributed verdict says so, not nothing', (
      tester,
    ) async {
      final db = seedWithProducer(null);
      addTearDown(db.close);

      await pumpList(tester, db);

      expect(find.byType(AttributionMark), findsOneWidget);
      expect(find.text('unattributed'), findsOneWidget);
    });

    testWidgets('an unsettled comparison claims no verifier', (tester) async {
      final db = seedDatabase(merged: false);
      addTearDown(db.close);

      await pumpList(tester, db);

      expect(find.text('open'), findsOneWidget);
      expect(find.byType(AttributionMark), findsNothing);
    });
  });

  group('the merge confirmation says who graded what is being merged', () {
    /// The merge action needs a live session row behind the candidate;
    /// `resultsFor` returns nothing without one, and the button stays off.
    AppDatabase seedMergeable(String? producerSessionId) {
      final db = seedDatabase(merged: false);
      AgentInstallationDao(db).insert(agentInstallation());
      SessionDao(db).insert(session(id: 's-win', title: 'The winner'));
      ComparisonDao(db).updateEvidence(
        'cand-win',
        CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          label: '12 tests, 0 failed',
          producerSessionId: producerSessionId,
        ),
      );
      return db;
    }

    Future<void> openMergeDialog(WidgetTester tester, AppDatabase db) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: Scaffold(
              body: ComparisonView(comparisonId: 'cmp-1', onBack: () {}),
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Merge').first);
      await tester.pumpAndSettle();
    }

    testWidgets('merging a self-graded candidate says it graded itself', (
      tester,
    ) async {
      final db = seedMergeable('s-win');
      addTearDown(db.close);

      await openMergeDialog(tester, db);

      expect(find.text('Merge claudeCode?'), findsOneWidget);
      expect(
        find.textContaining(VerdictAttribution.author.label),
        findsOneWidget,
      );
    });

    testWidgets('merging an unverified candidate does not imply a verdict', (
      tester,
    ) async {
      final db = seedMergeable(null);
      addTearDown(db.close);

      await openMergeDialog(tester, db);

      expect(
        find.textContaining(VerdictAttribution.notRecorded.label),
        findsOneWidget,
      );
    });
  });
}
