import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../application/session_activity_providers.dart';

/// How often the elapsed times are redrawn. One second, because the numbers are
/// seconds. The tick is a `setState` on this widget alone and exists only while
/// there is something to count, so a quiet session pays nothing.
const Duration kActivityTickInterval = Duration(seconds: 1);

/// **What this session is doing right now**, pinned above the composer: the
/// calls the agent has issued and not yet answered, and how long each has been
/// out. **Summary and elapsed, and nothing else** — the reader keeps a bounded
/// *head* of each result, so there is no live output to stream here.
///
/// It draws nothing when nothing is outstanding, but does draw one quiet line
/// when the session is working and no record can say what on: that empty answer
/// would otherwise read as "working on nothing". Conversation only.
class ActivityStrip extends ConsumerStatefulWidget {
  const ActivityStrip({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<ActivityStrip> createState() => _ActivityStripState();
}

class _ActivityStripState extends ConsumerState<ActivityStrip> {
  Timer? _tick;

  @override
  void dispose() {
    // Cancelled here, in the widget's own teardown, and not left to a provider
    // scope: a scope's scheduled auto-dispose is itself cancelled when the tree
    // unmounts, so a timer parked there outlives everything it was drawn for.
    _tick?.cancel();
    _tick = null;
    super.dispose();
  }

  /// Arms the tick if it is not already running. Idempotent, and safe from
  /// `build` — it schedules, it does not set state.
  void _startTicking() {
    _tick ??= Timer.periodic(kActivityTickInterval, (_) => setState(() {}));
  }

  void _stopTicking() {
    _tick?.cancel();
    _tick = null;
  }

  @override
  Widget build(BuildContext context) {
    // **Nothing ticks for a surface nobody can see.** A conversation kept
    // mounted behind the terminal went on calling `setState` once a second,
    // relaying itself out under every keystroke typed in front of it.
    //
    // `Visibility.of`, not `TickerMode.of`: an `IndexedStack` wraps its
    // unselected children in a `_VisibilityScope` and an `ExcludeFocus` and
    // nothing else, so the ticker is still enabled down here. Counted in
    // `test/app/shell/keystroke_cost_test.dart`.
    final visible = Visibility.of(context);
    final now = ref.read(clockProvider).nowUtc();
    final activity = ref.watch(
      sessionOutstandingCallsProvider(widget.sessionId),
    );
    final running = activity.calls;
    if (running.isEmpty) {
      // Nothing to count either way — a blind spot has no elapsed time, which
      // is part of what makes it a blind spot.
      _stopTicking();
      final spot = activity.blindSpot;
      return spot == null ? const SizedBox.shrink() : _BlindSpotLine(spot);
    }
    // Still drawn while hidden, so it is already the right size when the
    // surface comes back — it simply stops counting.
    if (visible) {
      _startTicking();
    } else {
      _stopTicking();
    }

    final theme = Theme.of(context);
    final colour = SemanticColors.of(context).working;
    final single = running.length == 1 ? running.first : null;
    // The oldest is the one worth naming: it is what a reader is waiting on.
    final oldest = running.reduce(
      (a, b) => a.startedAt.isBefore(b.startedAt) ? a : b,
    );
    final subagents = running.where((call) => call.isSubagent).length;

    final label = single != null
        ? single.summary
        : describeRunningMix(running.length, subagents);
    final elapsed = formatElapsed(oldest.ageAt(now));
    final trailing = single != null ? elapsed : 'oldest $elapsed';

    return Semantics(
      // Deliberately not a live region: the elapsed time changes every second,
      // and a screen reader announcing it every second would be unusable.
      label: single != null
          ? '${single.isSubagent ? 'Subagent' : 'Tool'} running: '
                '${single.summary}, $elapsed'
          : '$label, oldest $elapsed',
      child: Tooltip(
        message: [
          for (final call in running)
            '${call.isSubagent ? 'Subagent ' : ''}${call.summary} · '
                '${formatElapsed(call.ageAt(now))}',
        ].join('\n'),
        child: Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              // The app's own "working" glyph and colour, so this and the
              // status badge at the top of the view cannot describe one session
              // in two visual languages. A subagent gets its own mark — the one
              // call that is another agent — and keeps it when it is one of many.
              Icon(
                subagents > 0 ? AppIcons.robot : AppIcons.circleHalf,
                size: Chrome.iconSmall,
                color: colour,
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MonoStyles.small.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              Text(
                trailing,
                style: theme.textTheme.labelSmall?.copyWith(color: colour),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one line for a session that is working with nothing to say what on.
/// Neutral rather than "working"-coloured, and no elapsed time: this is an
/// admission, not a reading, and it must not look like one.
class _BlindSpotLine extends StatelessWidget {
  const _BlindSpotLine(this.spot);

  final ActivityBlindSpot spot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = SemanticColors.of(context).neutral;
    return Semantics(
      label: activityBlindSpotSentence(spot),
      child: Tooltip(
        message: activityBlindSpotDetail(spot),
        child: Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(AppIcons.question, size: Chrome.iconSmall, color: colour),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  activityBlindSpotSentence(spot),
                  maxLines: 2,
                  style: theme.textTheme.labelSmall?.copyWith(color: colour),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The desktop's wording for a blind spot. The value on the wire is a fact;
/// this is the sentence, and each end writes its own.
String activityBlindSpotSentence(ActivityBlindSpot spot) => switch (spot) {
  ActivityBlindSpot.noRecord => 'Working — no record here says what on',
};

/// The longer form, for the tooltip.
String activityBlindSpotDetail(ActivityBlindSpot spot) => switch (spot) {
  ActivityBlindSpot.noRecord =>
    'The status says this session is working. Nothing this app can read '
        'records which call is in flight, so it is named as unknown rather '
        'than shown as none.',
};

/// The collapsed label for several calls at once, kept honest about how many of
/// them are other agents.
String describeRunningMix(int total, int subagents) {
  final tools = total - subagents;
  if (subagents == 0) return '$total tools running';
  if (tools == 0) return '$subagents ${_plural('subagent', subagents)} running';
  return '$tools ${_plural('tool', tools)} and $subagents '
      '${_plural('subagent', subagents)} running';
}

String _plural(String word, int count) => count == 1 ? word : '${word}s';

/// How long a call has been out, in the smallest form that stays readable.
/// **It reaches hours, and it has to**: the longest unanswered tool window in
/// the owner's Claude Code store is a `Bash` call at 514.8 minutes, which now
/// reads `8h 34m`. What says a call is running is the session's own live
/// status, not this arithmetic.
String formatElapsed(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  if (seconds < 60) return '${seconds}s';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ${seconds % 60}s';
  return '${elapsed.inHours}h ${elapsed.inMinutes % 60}m';
}
