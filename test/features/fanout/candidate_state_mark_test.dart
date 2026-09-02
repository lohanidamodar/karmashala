import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_chrome.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_list.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_view.dart';

import '../../support/window_matrix.dart';
import 'comparison_fixtures.dart';

/// The mark that used to be a 7px coloured circle and nothing else.
///
/// Four states — did not start, winner, worktree removed, started — were
/// carried by hue alone: no glyph, no tooltip, no semantics, and an agent id
/// beside it that names the agent rather than the state. What is asserted here
/// is that the colour is now the *last* of three signals, so that removing it
/// entirely would still leave the four states told apart.
void main() {
  final light = SemanticColors.forBrightness(Brightness.light);

  ComparisonCandidate candidateWith({
    CandidateLaunchState launch = CandidateLaunchState.started,
    bool worktreeRemoved = false,
    String? failure,
  }) => ComparisonCandidate(
    id: 'cand',
    comparisonId: 'cmp-1',
    position: 0,
    installationId: 'a1',
    agentId: 'claudeCode',
    launch: launch,
    worktreeRemoved: worktreeRemoved,
    failure: failure,
  );

  /// The four states, each with the glyph, the word and the colour it must
  /// show. Written out rather than read back off the widget: this table *is*
  /// the user-facing vocabulary, so a change to it should have to be a change
  /// to a test.
  final states = <(String, CandidateStateMark, IconData, Color)>[
    (
      'never launched',
      CandidateStateMark(
        candidate: candidateWith(launch: CandidateLaunchState.failed),
      ),
      AppIcons.warningCircle,
      light.failure,
    ),
    (
      'the winner',
      CandidateStateMark(candidate: candidateWith(), isWinner: true),
      AppIcons.star,
      light.idle,
    ),
    (
      'worktree gone',
      CandidateStateMark(candidate: candidateWith(worktreeRemoved: true)),
      AppIcons.minusCircle,
      light.neutral,
    ),
    (
      'still in play',
      CandidateStateMark(candidate: candidateWith()),
      AppIcons.circleHalf,
      light.working,
    ),
  ];

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: Center(child: child)),
  );

  for (final (name, mark, glyph, colour) in states) {
    testWidgets('$name draws its own glyph, word and colour', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(mark));

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, glyph);
      expect(icon.color, colour);
      expect(icon.size, Chrome.iconSmall);

      // The word, in the tree Narrator reads — not only in a hover.
      expect(find.bySemanticsLabel(mark.state.label), findsOneWidget);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        isNotEmpty,
        reason: 'a pointer gets the sentence the glyph abbreviates',
      );
      handle.dispose();
    });
  }

  test('no two states share a glyph or a word', () {
    // The point of the whole change: strip the colour and four states are
    // still four states.
    expect(states.map((s) => s.$3).toSet(), hasLength(states.length));
    expect(states.map((s) => s.$2.state.label).toSet(), hasLength(4));
    expect(CandidateState.values.map((s) => s.label).toSet(), hasLength(4));
  });

  testWidgets('a recorded launch failure reaches the tooltip', (tester) async {
    // The card says this in words underneath; the list does not, and the list
    // is where a dot was the only thing anyone got.
    await tester.pumpWidget(
      host(
        CandidateStateMark(
          candidate: candidateWith(
            launch: CandidateLaunchState.failed,
            failure: 'Bad state: could not start flakyCli',
          ),
        ),
      ),
    );

    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      contains('could not start flakyCli'),
    );
  });

  group('the surfaces the mark grew inside', () {
    // It was 7px and is now Chrome.iconSmall. Both hosts put it at the head of
    // a row that already carries an agent id, a diff stat and buttons.
    Widget app(Widget child) => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(seedDatabase())],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: child),
      ),
    );

    testWidgets('the comparison view survives the window matrix', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(ComparisonView(comparisonId: 'cmp-1', onBack: () {})),
        because: 'the candidate row heads with the state mark',
      );
    });

    testWidgets('the comparisons list survives the window matrix', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(ComparisonList(onOpen: (_) {}, onNew: () {})),
        because: 'each candidate chip heads with the state mark',
      );
    });
  });
}
