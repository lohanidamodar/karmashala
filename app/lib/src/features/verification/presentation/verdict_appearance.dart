import 'package:flutter/widgets.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_verification/verification.dart';

/// How a verdict is drawn.
typedef VerdictAppearance = ({IconData icon, Color color, String label});

/// The one glyph, colour and word for a verdict, wherever it is drawn: the
/// verification pane, a fan-out candidate and a session's mark used to disagree.
/// Null is a run that has not concluded yet.
VerdictAppearance verdictAppearance(
  VerificationVerdict? verdict,
  SemanticColors semantic,
) => switch (verdict) {
  VerificationVerdict.pass => (
    icon: AppIcons.checkCircle,
    color: semantic.idle,
    label: VerificationVerdict.pass.label,
  ),
  VerificationVerdict.fail => (
    icon: AppIcons.xCircle,
    color: semantic.failure,
    label: VerificationVerdict.fail.label,
  ),
  // Attention, not neutral: "could not tell" is an answer worth a second look.
  VerificationVerdict.inconclusive => (
    icon: AppIcons.question,
    color: semantic.attention,
    label: VerificationVerdict.inconclusive.label,
  ),
  null => (icon: AppIcons.circleHalf, color: semantic.working, label: 'Open'),
};
