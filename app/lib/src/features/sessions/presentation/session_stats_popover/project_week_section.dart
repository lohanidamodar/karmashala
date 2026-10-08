// This project's week chart and its tight chart box.

part of '../session_stats_popover.dart';

/// This project's week: tokens by the day each of its sessions was last
/// active, as bars, with the attribution and any unrecorded sessions said.
/// Read only while the popover is open.
class _ProjectWeekSection extends ConsumerWidget {
  const _ProjectWeekSection({
    required this.sessionId,
    required this.width,
    required this.meta,
  });

  final String sessionId;
  final double width;
  final TextStyle? meta;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(projectWeekProvider(sessionId));
    final week = async.asData?.value;
    if (async.hasError && week == null) {
      return Text('This project’s week could not be read.', style: meta);
    }
    if (async.isLoading && week == null) {
      return Text('Reading this project’s sessions…', style: meta);
    }
    if (week == null) {
      return Text('This session is in no project.', style: meta);
    }
    if (week.sessions == 0) {
      return Text(
        'No session of ${week.projectName} recorded activity this week.',
        style: meta,
      );
    }
    String sessions(int n) => '$n ${n == 1 ? 'session' : 'sessions'}';
    final notes = <String>[
      'Each session’s tokens count on the day it was last active.',
      if (week.uncounted > 0)
        '${sessions(week.uncounted)} recorded no tokens and '
            '${week.uncounted == 1 ? 'is' : 'are'} not in the bars.',
    ];
    if (week.tokens == 0) {
      return Text(
        '${sessions(week.sessions)} of ${week.projectName} this week; token '
        'counts are $kStatNotRecorded for '
        '${week.sessions == 1 ? 'it' : 'any of them'}.',
        style: meta,
      );
    }
    final bars = [
      for (final day in week.days)
        BarDatum(
          label: _weekdays[day.day.weekday - 1],
          value: day.tokens.toDouble(),
          valueLabel: switch (day) {
            ProjectWeekDay(sessions: 0) => 'no sessions',
            ProjectWeekDay(sessions: final count, :final uncounted)
                when uncounted == count =>
              'tokens $kStatNotRecorded',
            _ =>
              '${formatCompactCount(day.tokens)} tokens · '
                  '${sessions(day.sessions)}',
          },
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TightChartBox(
          width: width,
          height: _weekChartHeight,
          child: BarChart(
            bars: bars,
            color: SemanticColors.of(context).working,
            height: _weekChartHeight,
            semanticsLabel:
                '${week.projectName} this week: '
                '${formatCompactCount(week.tokens)} tokens across '
                '${sessions(week.sessions)}. '
                '${bars.map((b) => '${b.label} ${b.spoken}').join(', ')}',
          ),
        ),
        const SizedBox(height: Insets.xs),
        for (final note in notes) Text(note, style: meta),
      ],
    );
  }
}

/// A box of a fixed size that **answers intrinsic and dry-layout questions
/// itself** and hands its child that size as tight constraints.
///
/// [BarChart] lays out through a LayoutBuilder, which cannot answer an
/// intrinsic or dry-layout question; a [MenuAnchor] asks them of everything in
/// its panel, and a failed answer closes the card as it opens. A plain SizedBox
/// forwards some of those questions to its child; this does not, so the child
/// is only ever laid out. A copy of the usage card's box, kept private to each
/// card so neither's layout depends on the other's file.
class _TightChartBox extends SingleChildRenderObjectWidget {
  const _TightChartBox({
    required this.width,
    required this.height,
    required Widget super.child,
  });

  final double width;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTightChartBox(Size(width, height));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTightChartBox renderObject,
  ) {
    renderObject.fixed = Size(width, height);
  }
}

class _RenderTightChartBox extends RenderProxyBox {
  _RenderTightChartBox(this._fixed);

  Size _fixed;
  set fixed(Size value) {
    if (value == _fixed) return;
    _fixed = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _fixed.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _fixed.width;

  @override
  double computeMinIntrinsicHeight(double width) => _fixed.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _fixed.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_fixed);

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => null;

  @override
  void performLayout() {
    size = constraints.constrain(_fixed);
    child?.layout(BoxConstraints.tight(size));
  }
}
