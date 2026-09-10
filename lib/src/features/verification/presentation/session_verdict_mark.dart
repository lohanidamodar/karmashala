import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/verification_providers.dart';
import '../domain/session_verdict.dart';

/// The one way a surface says whether a session's work was ever checked. It
/// always draws: a mark that rendered nothing when nothing had been checked
/// would look, in the row, like one that checked and found nothing wrong.
class SessionVerdictMark extends ConsumerWidget {
  const SessionVerdictMark({required this.sessionId, super.key});

  final String sessionId;

  /// Every state that is *not* a verdict takes the neutral colour: an absence
  /// is not a finding, and the label beside it says so in words.
  static Color _colourOf(BuildContext context, SessionVerdictState state) {
    final semantic = SemanticColors.of(context);
    return switch (state) {
      SessionVerdictState.pass => semantic.idle,
      SessionVerdictState.fail => semantic.failure,
      SessionVerdictState.inconclusive => semantic.attention,
      SessionVerdictState.inProgress => semantic.working,
      // An abandoned check is the one gap that is owed something — it is what
      // `FollowUpReason.verificationAbandoned` raises a notice for.
      SessionVerdictState.unfinished => semantic.attention,
      SessionVerdictState.notRecorded ||
      SessionVerdictState.verdictNotRecorded => semantic.neutral,
    };
  }

  static IconData _iconOf(SessionVerdictState state) => switch (state) {
    SessionVerdictState.pass => AppIcons.checkCircle,
    SessionVerdictState.fail => AppIcons.warningCircle,
    SessionVerdictState.inconclusive => AppIcons.question,
    SessionVerdictState.inProgress => AppIcons.circleHalf,
    SessionVerdictState.unfinished => AppIcons.minusCircle,
    SessionVerdictState.notRecorded ||
    SessionVerdictState.verdictNotRecorded => AppIcons.circle,
  };

  /// What the mark means, plus the run's own words where it left any. Never a
  /// sentence composed here about work nobody described.
  static String tooltipFor(SessionVerdict verdict) {
    final run = verdict.run;
    if (run == null) return verdict.state.explanation;
    final reason = run.reason?.trim();
    return [
      verdict.state.explanation,
      '“${run.title}”, ${run.attribution.phrase}.',
      if (reason != null && reason.isNotEmpty) reason,
      if (verdict.runCount > 1)
        '${verdict.runCount} runs name this session; this is the most recent.',
    ].join(' ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verdict = ref.watch(sessionVerdictProvider(sessionId));
    final theme = Theme.of(context);
    final colour = _colourOf(context, verdict.state);
    return Tooltip(
      message: tooltipFor(verdict),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A glyph as well as a colour, like the stage mark beside it: state
          // is never carried by colour alone.
          Icon(_iconOf(verdict.state), size: Chrome.iconSmall, color: colour),
          const SizedBox(width: 4),
          Text(
            verdict.state.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: colour),
          ),
        ],
      ),
    );
  }
}
