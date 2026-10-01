import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../application/store_attention.dart';
import 'stores_format.dart';

/// The colour a release state is drawn in: red when somebody must act, the
/// working accent while it moves, green when it is out, muted otherwise.
Color releaseStateColor(BuildContext context, ReleaseState state) {
  final semantic = SemanticColors.of(context);
  if (state.needsAttention) return semantic.failure;
  if (state.inFlight) return semantic.working;
  return switch (state) {
    ReleaseState.live => semantic.idle,
    ReleaseState.testing => semantic.working,
    _ => semantic.neutral,
  };
}

/// The colour a signal is drawn in.
Color signalColor(BuildContext context, StoreSignal signal) {
  final semantic = SemanticColors.of(context);
  return switch (signal) {
    ReleaseSignal(:final release) => releaseStateColor(context, release.state),
    NewReviewsSignal(:final unansweredLow) =>
      unansweredLow > 0 ? semantic.attention : semantic.unread,
    RatingDropSignal() => semantic.attention,
    UnreadSignal() => semantic.neutral,
  };
}

IconData signalIcon(StoreSignal signal) => switch (signal) {
  ReleaseSignal(:final release) => switch (release.state) {
    ReleaseState.rejected => AppIcons.xCircle,
    ReleaseState.halted => AppIcons.pauseCircle,
    ReleaseState.rollingOut => AppIcons.rocketLaunch,
    ReleaseState.pendingRelease => AppIcons.checkCircle,
    _ => AppIcons.clock,
  },
  NewReviewsSignal() => AppIcons.chatCircle,
  RatingDropSignal() => AppIcons.arrowDown,
  UnreadSignal() => AppIcons.warning,
};

/// A signal in a few words, for a pill: `3.2.0 Rejected`, `2 new reviews`.
String signalShortText(StoreSignal signal) => switch (signal) {
  ReleaseSignal(:final release) => [
    if (!isPublicTrack(release.track)) formatTrack(release.track),
    formatVersion(release),
    formatReleaseState(release),
  ].join(' · '),
  NewReviewsSignal(:final count, :final unansweredLow) => [
    '$count new ${count == 1 ? 'review' : 'reviews'}',
    if (unansweredLow > 0) '$unansweredLow low, unanswered',
  ].join(' · '),
  RatingDropSignal(:final change) => 'Rating ${formatRatingChange(change)}',
  UnreadSignal(:final area) => '${area.label} unavailable',
};

/// A signal as a sentence that names its store, for the detail.
String signalSentence(StoreSignal signal) {
  final store = signal.store.label;
  return switch (signal) {
    ReleaseSignal(:final release) => _releaseSentence(store, release),
    NewReviewsSignal(:final count, :final unansweredLow) =>
      '$store: $count new ${count == 1 ? 'review' : 'reviews'} this week'
          '${unansweredLow > 0 ? ', $unansweredLow of one or two stars not answered' : ''}.',
    RatingDropSignal(:final change, :final since) =>
      '$store: the rating fell ${formatRatingChange(change).substring(1)} '
          'since ${formatReportDay(since)}.',
    UnreadSignal(:final area, :final message) =>
      '$store: ${area.label.toLowerCase()} could not be read. $message',
  };
}

String _releaseSentence(String store, StoreRelease release) {
  final version = formatVersion(release);
  final track = isPublicTrack(release.track)
      ? ''
      : ' on ${formatTrack(release.track)}';
  final fraction = release.rolloutFraction;
  final what = switch (release.state) {
    ReleaseState.rejected =>
      'was rejected$track. The console says why and what to change',
    ReleaseState.halted => 'is halted$track; its rollout is paused',
    ReleaseState.rollingOut =>
      fraction == null
          ? 'is in a staged rollout$track; Google Play does not say the share '
                'to a read-only key'
          : 'is rolling out$track, to ${(fraction * 100).round()}% of users',
    ReleaseState.pendingRelease =>
      'is approved$track and waiting to be released',
    ReleaseState.inReview => 'is in review$track',
    ReleaseState.waitingForReview => 'is waiting for review$track',
    ReleaseState.processing => 'is processing$track',
    final state => 'is ${state.label.toLowerCase()}$track',
  };
  return '$store: $version $what.';
}

/// A short status in a tinted capsule: the colour carries the tone, the words
/// carry the meaning, so it never relies on colour alone.
class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    required this.color,
    this.icon,
    this.tooltip,
    super.key,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glyph = icon;
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: StateLayers.selectedAlpha),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (glyph != null) ...[
              Icon(glyph, size: Chrome.iconAction, color: color),
              const SizedBox(width: Insets.xs),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip, child: pill);
  }
}

/// One signal as a [StatusPill], its sentence on hover.
class SignalPill extends StatelessWidget {
  const SignalPill({required this.signal, this.showStore = false, super.key});

  final StoreSignal signal;

  /// Whether to name the store: on a card whose rows do not already.
  final bool showStore;

  @override
  Widget build(BuildContext context) {
    final text = signalShortText(signal);
    return StatusPill(
      label: showStore ? '${storeShortLabel(signal.store)} · $text' : text,
      color: signalColor(context, signal),
      icon: signalIcon(signal),
      tooltip: signalSentence(signal),
    );
  }
}

/// A release's state as a pill.
class ReleaseStatePill extends StatelessWidget {
  const ReleaseStatePill({required this.release, super.key});

  final StoreRelease release;

  @override
  Widget build(BuildContext context) => StatusPill(
    label: formatReleaseState(release),
    color: releaseStateColor(context, release.state),
    tooltip: release.rawState.isEmpty
        ? null
        : 'The store says ${release.rawState}',
  );
}

/// How far a phased or staged rollout has got, as a thin bar.
class RolloutBar extends StatelessWidget {
  const RolloutBar({required this.fraction, this.width = 56, super.key});

  final double fraction;
  final double width;

  @override
  Widget build(BuildContext context) {
    final color = SemanticColors.of(context).working;
    return Semantics(
      label: 'Rolled out to ${(fraction * 100).round()}% of users',
      child: SizedBox(
        width: width,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: LinearProgressIndicator(
            value: fraction.clamp(0, 1),
            minHeight: 4,
            color: color,
            backgroundColor: color.withValues(alpha: StateLayers.selectedAlpha),
          ),
        ),
      ),
    );
  }
}

/// `★ 4.6` with its week's change beside it when there is one.
class RatingFigure extends StatelessWidget {
  const RatingFigure({required this.rating, this.style, super.key});

  final RatingSummary rating;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final base = (style ?? theme.textTheme.bodySmall)?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final trend = rating.trend;
    final rounded = trend == null ? 0.0 : (trend.change * 10).round() / 10;
    final (glyph, color) = rounded > 0
        ? (AppIcons.arrowUp, semantic.idle)
        : rounded < 0
        ? (AppIcons.arrowDown, semantic.attention)
        : (null, null);
    final count = rating.count;
    final spoken = [
      '${rating.average.toStringAsFixed(1)} of 5 stars',
      if (count != null) 'from $count ratings',
      if (trend != null && rounded != 0)
        '${formatRatingChange(trend.change)} since ${formatReportDay(trend.since)}',
    ].join(', ');
    return Semantics(
      label: spoken,
      child: ExcludeSemantics(
        child: Tooltip(
          message: spoken,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.star,
                size: Chrome.iconAction,
                color: semantic.attention,
              ),
              const SizedBox(width: 2),
              Text(rating.average.toStringAsFixed(1), style: base),
              if (glyph != null && trend != null) ...[
                const SizedBox(width: Insets.xs),
                Icon(glyph, size: Chrome.iconAction - 2, color: color),
                Text(
                  formatRatingChange(trend.change).substring(1),
                  style: base?.copyWith(color: color),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A missing reading said inline in the detail: quietly when it is the
/// store's or the setup's doing, in the warning tone when it is a fault.
class MissingReadingLine extends StatelessWidget {
  const MissingReadingLine({
    required this.what,
    required this.reading,
    super.key,
  });

  final String what;
  final ReadingMissing<Object?> reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final expected = reading.expected;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            expected ? AppIcons.info : AppIcons.warning,
            size: Chrome.iconSmall,
            color: expected
                ? scheme.onSurfaceVariant
                : SemanticColors.of(context).attention,
          ),
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$what  ',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(text: reading.message),
              ],
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: expected ? scheme.onSurfaceVariant : null,
            ),
          ),
        ),
      ],
    );
  }
}
