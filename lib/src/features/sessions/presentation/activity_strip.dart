import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../application/session_activity_providers.dart';

/// How often the elapsed times are redrawn.
///
/// One second, because the numbers are seconds. The tick is a `setState` on
/// this widget alone — it never touches the transcript above it — and it exists
/// only while there is something to count, so a quiet session pays nothing.
const Duration kActivityTickInterval = Duration(seconds: 1);

/// **What this session is doing right now**, pinned above the composer.
///
/// The chat view had no at-a-glance answer to that question: in-flight work was
/// visible only if you scrolled to the bottom of the transcript and noticed a
/// tool row with no result under it. This is that same fact, held still.
///
/// It shows the calls the agent has issued and not yet answered — the summary
/// the transcript already prints, plus how long each has been out. **Summary
/// and elapsed, and nothing else**: the reader keeps a bounded *head* of each
/// result rather than a tail, so there is no live output to stream here and
/// pretending otherwise would mean inventing one.
///
/// It draws nothing at all when nothing is outstanding — no empty box, no
/// reserved row — because that is the common case and it must cost the reader
/// nothing. What decides "outstanding" and what retires a call that only *looks*
/// outstanding is [sessionOutstandingCallsProvider]; this widget adds the clock.
///
/// Conversation only. A terminal pane already shows the CLI printing, and a
/// second copy of it beside the first is noise.
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
    // **Nothing ticks for a surface nobody can see.** `WorkbenchView` keeps a
    // conversation that has been asked for mounted behind the terminal so the
    // toggle preserves its scroll position — and the strip went on calling
    // `setState` once a second underneath it, rebuilding and laying itself out
    // under every keystroke the user typed into the terminal in front of it.
    //
    // `Visibility.of`, not `TickerMode.of`: an `IndexedStack` wraps its
    // unselected children in a `_VisibilityScope` and an `ExcludeFocus` and
    // nothing else — painting and hit-testing are the render object's job — so
    // the ticker is still enabled down here and only this asks the question
    // that was actually answered. Counted in
    // `test/app/shell/keystroke_cost_test.dart`.
    final visible = Visibility.of(context);
    final now = ref.read(clockProvider).nowUtc();
    final running = ref
        .watch(sessionOutstandingCallsProvider(widget.sessionId))
        .runningAt(now);
    if (running.isEmpty) {
      _stopTicking();
      return const SizedBox.shrink();
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

    final label = single != null
        ? single.summary
        : '${running.length} tools running';
    final elapsed = formatElapsed(oldest.ageAt(now));
    final trailing = single != null ? elapsed : 'oldest $elapsed';

    return Semantics(
      // Deliberately not a live region: the elapsed time changes every second,
      // and a screen reader announcing it every second would be unusable.
      label: single != null
          ? '${single.isSubagent ? 'Subagent' : 'Tool'} running: '
                '${single.summary}, $elapsed'
          : '${running.length} tools running, oldest $elapsed',
      child: Tooltip(
        message: [
          for (final call in running)
            '${call.summary} · ${formatElapsed(call.ageAt(now))}',
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
              // status badge at the top of the view cannot describe the same
              // session in two different visual languages. A subagent gets its
              // own mark: it is the one call that is another agent.
              Icon(
                single != null && single.isSubagent
                    ? AppIcons.robot
                    : AppIcons.circleHalf,
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

/// How long a call has been out, in the smallest form that stays readable.
///
/// Never reaches hours: [kOutstandingCallMaxAge] retires a call long before
/// that, and a line reading `4h12m` is exactly the claim this feature must
/// never make.
String formatElapsed(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  if (seconds < 60) return '${seconds}s';
  return '${elapsed.inMinutes}m ${seconds % 60}s';
}
