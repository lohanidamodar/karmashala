import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_ui/rows.dart';
import '../application/session_activity_providers.dart';

/// **What this session is doing right now**, pinned above the composer: summary
/// and elapsed only. Silent when idle, but never silent about a blind spot.
class ActivityStrip extends ConsumerStatefulWidget {
  const ActivityStrip({required this.sessionId, this.onStop, super.key});

  final String sessionId;

  /// Stops the running turn — board N2's `Stop · Esc` pill. Null draws no
  /// pill: only a host that owns the Esc binding and the pane may offer it.
  final VoidCallback? onStop;

  @override
  ConsumerState<ActivityStrip> createState() => _ActivityStripState();
}

class _ActivityStripState extends ConsumerState<ActivityStrip> {
  Timer? _tick;

  @override
  void dispose() {
    // Cancelled in the widget's own teardown, not left to a provider scope: a
    // scope's auto-dispose is itself cancelled when the tree unmounts.
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
    // **Nothing ticks for a surface nobody can see.** `Visibility.of`, not
    // `TickerMode.of`: an `IndexedStack` only wraps a `_VisibilityScope`.
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

    // Board N2's live line: a spinner, muted "what · how long", and a small
    // Stop pill — a line of the conversation, not a boxed widget over it.
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final onStop = widget.onStop;
    return Semantics(
      // Deliberately not a live region: the elapsed time changes every second,
      // and a screen reader announcing it every second would be unusable.
      label: single != null
          ? '${single.isSubagent ? 'Subagent' : 'Tool'} running: '
                '${single.summary}, $elapsed'
          : '$label, oldest $elapsed',
      child: Padding(
        padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
        child: Row(
          children: [
            Flexible(
              child: Tooltip(
                message: [
                  for (final call in running)
                    '${call.isSubagent ? 'Subagent ' : ''}${call.summary} · '
                        '${formatElapsed(call.ageAt(now))}',
                ].join('\n'),
                child: Row(
                  children: [
                    // The app's own "working" glyph and colour, so this and
                    // the status badge cannot describe one session in two
                    // languages.
                    if (subagents > 0)
                      Icon(
                        AppIcons.robot,
                        size: Chrome.iconSmall,
                        color: colour,
                      )
                    else
                      WorkingSpinner(size: Chrome.iconSmall, color: colour),
                    const SizedBox(width: Insets.sm),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                    Text(' · ', style: muted),
                    Text(trailing, maxLines: 1, style: muted),
                  ],
                ),
              ),
            ),
            if (onStop != null) ...[
              const SizedBox(width: Insets.sm),
              _StopPill(onPressed: onStop),
            ],
          ],
        ),
      ),
    );
  }
}

/// Board N2's `Stop · Esc`: a small outlined pill, the key named on it because
/// it is the faster way and nothing else in the chat says so.
class _StopPill extends StatelessWidget {
  const _StopPill({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A phone has no Esc to name, and a thumb needs the touch floor.
    final touch = UiDensity.of(context).isTouch;
    return Semantics(
      // Its own node: merged into the strip's, the strip would read as a
      // button and its label would gain this one.
      container: true,
      button: true,
      label: touch ? 'Stop the running turn' : 'Stop the running turn (Esc)',
      excludeSemantics: true,
      child: Tooltip(
        message: touch
            ? 'Stop the running turn'
            : 'Stop the running turn — types Esc into its terminal',
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Container(
            constraints: touch
                ? const BoxConstraints(
                    minHeight: Touch.target,
                    minWidth: Touch.target,
                  )
                : null,
            alignment: touch ? Alignment.center : null,
            padding: EdgeInsets.symmetric(
              horizontal: touch ? Insets.md : Insets.sm,
              vertical: Insets.hair * 2,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              touch ? 'Stop' : 'Stop · Esc',
              maxLines: 1,
              style:
                  (touch
                          ? theme.textTheme.labelLarge
                          : theme.textTheme.labelSmall)
                      ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one line for a session that is working with nothing to say what on.
/// Neutral and no elapsed time: this is an admission, not a reading.
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
        // Unboxed, like the running line it stands in for (board N2).
        child: Padding(
          padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
          child: Row(
            children: [
              Icon(AppIcons.question, size: Chrome.iconSmall, color: colour),
              const SizedBox(width: Insets.sm),
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
