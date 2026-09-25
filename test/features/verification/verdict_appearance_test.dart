import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_chrome.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';
import 'package:karmashala/src/features/verification/domain/session_verdict.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:karmashala/src/features/verification/presentation/session_verdict_mark.dart';
import 'package:karmashala/src/features/verification/presentation/verdict_appearance.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

final _semantic = SemanticColors.forBrightness(Brightness.light);

VerdictAppearance appearance(VerificationVerdict? verdict) =>
    verdictAppearance(verdict, _semantic);

Widget _host(Widget child, {SessionVerdictState? state, double width = 400}) =>
    ProviderScope(
      overrides: [
        sessionVerdictProvider.overrideWith(
          (ref, id) =>
              SessionVerdict(state: state ?? SessionVerdictState.notRecorded),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

Icon _iconIn(WidgetTester tester, Type owner) => tester.widget<Icon>(
  find.descendant(of: find.byType(owner), matching: find.byType(Icon)).first,
);

void main() {
  group('verdictAppearance is the one mapping', () {
    test('each verdict has its own glyph, colour and word', () {
      expect(appearance(VerificationVerdict.pass), (
        icon: AppIcons.checkCircle,
        color: _semantic.idle,
        label: 'Pass',
      ));
      expect(appearance(VerificationVerdict.fail), (
        icon: AppIcons.xCircle,
        color: _semantic.failure,
        label: 'Fail',
      ));
      expect(appearance(VerificationVerdict.inconclusive), (
        icon: AppIcons.question,
        color: _semantic.attention,
        label: 'Inconclusive',
      ));
      expect(appearance(null).label, 'Open');
    });
  });

  group('every surface draws a verdict the same way', () {
    for (final (evidence, verdict, state) in [
      (
        EvidenceVerdict.passed,
        VerificationVerdict.pass,
        SessionVerdictState.pass,
      ),
      (
        EvidenceVerdict.failed,
        VerificationVerdict.fail,
        SessionVerdictState.fail,
      ),
      (
        EvidenceVerdict.inconclusive,
        VerificationVerdict.inconclusive,
        SessionVerdictState.inconclusive,
      ),
    ]) {
      testWidgets('${verdict.name}: a fan-out candidate and a session mark', (
        tester,
      ) async {
        final expected = appearance(verdict);

        await tester.pumpWidget(
          _host(
            VerdictChip(
              evidence: CandidateEvidence(verdict: evidence, label: 'label'),
              attribution: VerdictAttribution.notRecorded,
            ),
          ),
        );
        final chip = _iconIn(tester, VerdictChip);
        expect((chip.icon, chip.color), (expected.icon, expected.color));

        await tester.pumpWidget(
          _host(const SessionVerdictMark(sessionId: 's1'), state: state),
        );
        final mark = _iconIn(tester, SessionVerdictMark);
        expect((mark.icon, mark.color), (expected.icon, expected.color));
      });
    }
  });

  testWidgets('a session mark ellipsises in a narrow host', (tester) async {
    await tester.pumpWidget(
      _host(
        const Row(
          children: [Flexible(child: SessionVerdictMark(sessionId: 's1'))],
        ),
        state: SessionVerdictState.verdictNotRecorded,
        width: 64,
      ),
    );
    expect(tester.takeException(), isNull, reason: 'no overflow');
    final text = tester.widget<Text>(find.text('Verdict not recorded'));
    expect(text.overflow, TextOverflow.ellipsis);
    expect(
      tester.getSize(find.text('Verdict not recorded')).width,
      lessThanOrEqualTo(64),
    );
  });
}
