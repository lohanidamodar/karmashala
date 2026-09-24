import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/verification_providers.dart';
import '../domain/session_verdict.dart';
import '../domain/verification_run.dart';
import 'verdict_appearance.dart';

/// The one way a surface says whether a session's work was ever checked. It
/// always draws: a mark that rendered nothing when nothing had been checked
/// would look, in the row, like one that checked and found nothing wrong.
class SessionVerdictMark extends ConsumerWidget {
  const SessionVerdictMark({required this.sessionId, super.key});

  final String sessionId;

  /// A verdict is drawn by [verdictAppearance], like everywhere else. Every
  /// state that is *not* a verdict takes the neutral colour: an absence is not
  /// a finding, and the label beside it says so in words.
  static ({IconData icon, Color color}) appearanceOf(
    SessionVerdictState state,
    SemanticColors semantic,
  ) {
    final verdict = switch (state) {
      SessionVerdictState.pass => VerificationVerdict.pass,
      SessionVerdictState.fail => VerificationVerdict.fail,
      SessionVerdictState.inconclusive => VerificationVerdict.inconclusive,
      _ => null,
    };
    if (verdict != null) {
      final look = verdictAppearance(verdict, semantic);
      return (icon: look.icon, color: look.color);
    }
    return switch (state) {
      SessionVerdictState.inProgress => (
        icon: AppIcons.circleHalf,
        color: semantic.working,
      ),
      // An abandoned check is the one gap that is owed something — it is what
      // `FollowUpReason.verificationAbandoned` raises a notice for.
      SessionVerdictState.unfinished => (
        icon: AppIcons.minusCircle,
        color: semantic.attention,
      ),
      _ => (icon: AppIcons.circle, color: semantic.neutral),
    };
  }

  /// What the mark means, plus the run's own words where it left any. Never a
  /// sentence composed here about work nobody described.
  static String tooltipFor(SessionVerdict verdict) {
    final run = verdict.run;
    if (run == null) return verdict.state.explanation;
    final reason = run.reason?.trim();
    final finished = run.finishedAt?.toLocal();
    return [
      verdict.state.explanation,
      '“${run.title}”, ${run.attribution.phrase}'
          '${finished == null ? '' : ', recorded ${_clock(finished)}'}.',
      if (reason != null && reason.isNotEmpty) reason,
      if (verdict.runCount > 1)
        '${verdict.runCount} runs name this session; this is the most recent.',
    ].join(' ');
  }

  /// A clock time, not an age: the tooltip is built when the mark is, and an
  /// age written then goes on being read long after it stopped being true.
  static String _clock(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final time = '${two(at.hour)}:${two(at.minute)}';
    return sameDay
        ? 'at $time'
        : 'on ${at.year}-${two(at.month)}-${two(at.day)} $time';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verdict = ref.watch(sessionVerdictProvider(sessionId));
    final theme = Theme.of(context);
    final look = appearanceOf(verdict.state, SemanticColors.of(context));
    final colour = look.color;
    return Tooltip(
      message: tooltipFor(verdict),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A glyph as well as a colour, like the stage mark beside it: state
          // is never carried by colour alone.
          Icon(look.icon, size: Chrome.iconSmall, color: colour),
          const SizedBox(width: Insets.xs),
          // Flexible, or the ellipsis never takes effect and a narrow host
          // overflows instead.
          Flexible(
            child: Text(
              verdict.state.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: colour),
            ),
          ),
        ],
      ),
    );
  }
}
