// The running mark and the state badge on a project's line.
part of '../project_card.dart';

/// What says "running" ahead of its count: the shared [WorkingSpinner] while a
/// session is in a turn, a filled dot while what runs is waiting. Both stand in
/// one [slot], so a turn starting moves nothing on the line.
class ProjectRunningMark extends StatelessWidget {
  const ProjectRunningMark({
    required this.working,
    required this.slot,
    required this.color,
    super.key,
  });

  final bool working;
  final double slot;
  final Color color;

  /// A bullet, not a glyph: at the slot's full size a dot reads as an icon the
  /// count belongs to.
  static const _dot = 8.0;

  /// Between the mark and its count.
  static const gap = 3.0;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: slot,
    child: Center(
      child: working
          ? WorkingSpinner(size: slot, color: color)
          : Icon(AppIcons.circleFill, size: _dot, color: color),
    ),
  );
}

/// `● 2` or `⚠ 1` — and, [inWords], `● 2 running` or `⚠ 1 needs you`; the dot
/// is the turning [WorkingSpinner] while a session works. A glyph with its
/// count, never a colour alone, and the sentence as the tooltip.
class ProjectStateBadge extends StatelessWidget {
  const ProjectStateBadge._({
    required this.running,
    required this.count,
    required this.words,
    required this.tooltip,
    this.working = false,
    super.key,
  });

  factory ProjectStateBadge.running(
    ProjectSummary summary, {
    bool inWords = false,
    Key? key,
  }) => ProjectStateBadge._(
    key: key,
    running: true,
    working: summary.working > 0,
    count: summary.active,
    words: inWords ? summary.runningLabel : null,
    tooltip: summary.runningTooltip ?? '',
  );

  factory ProjectStateBadge.needsYou(
    ProjectSummary summary, {
    bool inWords = false,
    Key? key,
  }) => ProjectStateBadge._(
    key: key,
    running: false,
    count: summary.needsAttention,
    words: inWords ? summary.attentionLabel : null,
    tooltip: summary.attentionLabel ?? '',
  );

  final bool running;

  /// Whether the running mark turns: a session is in a turn right now.
  final bool working;
  final int count;
  final String? words;
  final String tooltip;

  /// Ahead of every badge, so a line that has none reserves nothing.
  static const _gapBefore = Insets.sm;

  /// How wide [summary]'s badges draw, [measure] being the caller's painter —
  /// the arithmetic of [build], so a line can decide what else fits.
  static double widthOf(
    ProjectSummary summary,
    UiDensity density,
    double Function(String text, [TextStyle? style]) measure, {
    required bool inWords,
  }) {
    var width = 0.0;
    if (summary.active > 0) {
      width +=
          _gapBefore +
          density.iconSmall +
          ProjectRunningMark.gap +
          measure(
            inWords ? summary.runningLabel! : '${summary.active}',
            _figures,
          );
    }
    if (summary.needsAttention > 0) {
      width +=
          _gapBefore +
          density.iconSmall +
          Insets.hair +
          measure(
            inWords ? summary.attentionLabel! : '${summary.needsAttention}',
            _figures.copyWith(fontWeight: FontWeight.w600),
          );
    }
    return width;
  }

  /// Counts are drawn in tabular figures, wider than plain ones in most fonts.
  static const _figures = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final color = running ? semantic.working : semantic.attention;
    final style = density
        .muted(theme)
        ?.copyWith(
          color: color,
          fontWeight: running ? null : FontWeight.w600,
          fontFeatures: _figures.fontFeatures,
        );
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: _gapBefore),
          if (running)
            ProjectRunningMark(
              working: working,
              slot: density.iconSmall,
              color: color,
            )
          else
            AskGlyph(size: density.iconSmall),
          SizedBox(width: running ? ProjectRunningMark.gap : Insets.hair),
          Text(words ?? '$count', maxLines: 1, softWrap: false, style: style),
        ],
      ),
    );
  }
}
