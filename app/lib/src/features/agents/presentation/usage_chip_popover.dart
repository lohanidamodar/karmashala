import 'dart:math' as math;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/panes.dart' show EyebrowLabel;
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environments_controller.dart';
import '../application/agent_account_switch.dart';
import '../application/usage_history.dart';
import 'agent_logo.dart';
import 'usage_chip.dart' show UsageChipView, formatResetClock;
import 'usage_history_charts.dart'
    show kUsageHistoryWindow, samplesOf, usageHistoryQuery, usageSeriesSummary;
import 'usage_machine_switcher.dart';
import 'usage_tab/usage_windows_section.dart'
    show clipForecast, usageForecastOf;
import 'usage_window_meter.dart';

/// The width the card is laid out at, window permitting. Fixed rather than
/// "at most": the card sits in a [MenuAnchor], which sizes its panel from
/// intrinsic widths, and a tight width is what lets the chart inside be told
/// its size instead of asked for it. 344 leaves the chart the 320px it needs
/// to keep its axis labels.
const double kUsagePopoverWidth = 344;

/// The card's inner padding, which the chart's width is worked out from.
const double _pad = Insets.md;

/// The 7-day chart's height.
const double _chartHeight = 96;

/// How far past now the chart looks for the forecast: a day of a week-long
/// range, so the recorded part keeps most of the width.
const Duration _forecastHorizon = Duration(days: 1);

/// **An account's usage card** (spec §5 "Account usage"), opened from its
/// toolbar chip: who the account is and its plan; the machines that use it,
/// each with an account switcher; every window with what is used, when it
/// resets and how the pace compares; the last seven days of the account's
/// tightest long window with the run-out forecast dashed ahead; the reading's
/// notes; and the popup's own actions in [footer]. Falls back to the chip's
/// own sentence where the windows would be when there is no reading to draw.
///
/// Calm per spec §3: the raised tone, the floating hairline, a popover
/// radius, 13px rows and 11px uppercase group labels.
///
/// **No LayoutBuilder anywhere under it.** The menu measures its content's
/// intrinsic size, which a LayoutBuilder refuses — a sparkline that used one
/// made the card close as it opened. The width is fixed, and the one child
/// that does lay out by constraints, the chart, sits in [_TightChartBox],
/// which answers the menu's questions itself.
class UsageChipPopover extends ConsumerWidget {
  const UsageChipPopover({
    required this.view,
    required this.accountKey,
    required this.agentId,
    required this.environmentId,
    this.environmentIds,
    this.footer,
    super.key,
  });

  final UsageChipView view;
  final String accountKey;
  final String agentId;
  final String environmentId;

  /// Every environment the account is signed in from, one machine row each;
  /// [environmentId] alone when null.
  final List<String>? environmentIds;

  /// What ends the card instead of its "click for more" line: a popup's own
  /// actions.
  final Widget? footer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final body13 = theme.textTheme.bodyMedium?.copyWith(
      fontSize: TypeSizes.body,
    );
    final meta = theme.textTheme.bodySmall?.copyWith(
      fontSize: TypeSizes.label,
      color: scheme.onSurfaceVariant,
    );
    final now = ref.watch(clockProvider).nowUtc();
    final reading = view.reading;
    final email = reading?.email;
    final agentName = AgentRegistry.builtIn.displayNameFor(agentId);
    final plan = usageSavedPlanOf(ref, agentId, email);
    // Under the account: whose it is and its plan, when either adds anything.
    final subtitle = [if (email != null) agentName, ?plan].join(' · ');

    // The window can be narrower than the card at a large text size or a
    // small window; the card gives way rather than overflow it.
    final screen = MediaQuery.sizeOf(context).width;
    final width = math.max(
      200.0,
      math.min(kUsagePopoverWidth, screen - Insets.lg * 2),
    );
    final inner = width - _pad * 2;

    final header = Row(
      children: [
        AgentLogo(agentId: agentId, size: 15, color: scheme.onSurface),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                email ?? agentName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: body13?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: meta,
                ),
            ],
          ),
        ),
      ],
    );

    final body = <Widget>[
      const _GroupLabel('Machines'),
      for (final id in environmentIds ?? [environmentId])
        _MachineRow(
          agentId: agentId,
          environmentId: id,
          label: ref.watch(environmentLabelForIdProvider(id)),
          email: email,
          style: body13,
        ),
    ];
    // Said in the card that holds the machine now: after a switch, the new
    // account's.
    final switched = ref.watch(accountSwitchControllerProvider).last;
    if (switched != null &&
        switched.agentId == agentId &&
        (environmentIds ?? [environmentId]).contains(switched.environmentId)) {
      final machine = ref.watch(
        environmentLabelForIdProvider(switched.environmentId),
      );
      final failure = switched.failure;
      body.add(
        Padding(
          padding: const EdgeInsets.only(top: Insets.xs),
          child: Text(
            failure == null
                ? 'Switched $machine to ${switched.account}.'
                : 'Could not switch $machine: $failure',
            key: const ValueKey('usage-switch-outcome'),
            style: meta?.copyWith(
              color: failure == null
                  ? null
                  : SemanticColors.of(context).failure,
            ),
          ),
        ),
      );
    }
    if (reading == null || reading.windows.every((w) => w.percent == null)) {
      body
        ..add(const SizedBox(height: Insets.sm))
        ..add(Text(view.tooltip, style: meta));
    } else {
      body.add(const _GroupLabel('Windows'));
      for (final window in reading.windows) {
        body.add(
          UsageWindowMeter(window: window, readAt: reading.fetchedAt, now: now),
        );
      }
      // Asked of the server; the last answer stays while a newer one comes.
      final history =
          ref
              .watch(usageHistoryProvider(usageHistoryQuery(accountKey, now)))
              .value ??
          const <UsageSample>[];
      body.add(
        _WeekChart(
          usage: reading,
          history: history,
          now: now,
          width: inner,
          meta: meta,
        ),
      );
    }
    // The account is the header; the rest of the notes — the sign-in's
    // lifetime, the reading's age, a failure — close the body.
    final notes = [
      for (final note in view.notes)
        if (note != email) note,
    ];
    if (notes.isNotEmpty) {
      body.add(const SizedBox(height: Insets.sm));
      for (final note in notes) {
        body.add(Text(note, style: meta));
      }
    }

    // A card taller than the window scrolls its body; the header and the way
    // on stay.
    final maxHeight = MediaQuery.sizeOf(context).height - Insets.xl * 2;
    return SizedBox(
      width: width,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxHeight < 160 ? 160 : maxHeight,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tones.raised,
            border: Border.all(color: tones.floatingLine),
            borderRadius: BorderRadius.circular(Radii.lg),
            boxShadow: Shadows.floating,
          ),
          child: DefaultTextStyle(
            style: body13 ?? const TextStyle(fontSize: TypeSizes.body),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_pad, _pad, _pad, Insets.xs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  Flexible(
                    child: SingleChildScrollView(
                      primary: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: body,
                      ),
                    ),
                  ),
                  const SizedBox(height: Insets.sm),
                  Divider(height: 1, thickness: 1, color: tones.floatingLine),
                  const SizedBox(height: Insets.xs),
                  footer ??
                      Padding(
                        padding: const EdgeInsets.only(bottom: Insets.sm),
                        child: Text(
                          'Click for usage & limits',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: meta,
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An 11px uppercase group label, with the air above it that separates one
/// group of the card from the last.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => EyebrowLabel(
    text,
    maxLines: 1,
    padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
  );
}

/// One machine the account is signed in from: its name, and the switcher that
/// signs it in as another saved account where its agent allows one.
class _MachineRow extends StatelessWidget {
  const _MachineRow({
    required this.agentId,
    required this.environmentId,
    required this.label,
    required this.email,
    required this.style,
  });

  final String agentId;
  final String environmentId;
  final String label;
  final String? email;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // A 28px row, spec §3's compact density.
      constraints: const BoxConstraints(minHeight: 28),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          UsageMachineSwitcher(
            agentId: agentId,
            environmentId: environmentId,
            currentEmail: email,
          ),
        ],
      ),
    );
  }
}

/// **The last seven days** of the account's week-long window — the tightest
/// measured one when it has none — with the run-out forecast dashed ahead of
/// the last reading. The same forecast the Usage tab draws, so the two never
/// disagree; a sentence instead when fewer than two readings exist.
class _WeekChart extends StatelessWidget {
  const _WeekChart({
    required this.usage,
    required this.history,
    required this.now,
    required this.width,
    required this.meta,
  });

  final AgentUsage usage;
  final List<UsageSample> history;
  final DateTime now;
  final double width;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final measured = [
      for (final w in usage.windows)
        if (w.percent != null) w,
    ];
    if (measured.isEmpty) return const SizedBox.shrink();
    final weekly = measured.where((w) => w.span == kUsageSevenDayWindow);
    final window = weekly.isNotEmpty
        ? weekly.first
        : measured.reduce((a, b) => b.percent! > a.percent! ? b : a);

    final start = now.subtract(kUsageHistoryWindow);
    final series = samplesOf(history, window.label, from: start);
    final forecast = usageForecastOf(window, usage.fetchedAt);
    final horizon = now.add(_forecastHorizon);
    final forecastEnd = forecast.isEmpty ? now : forecast.last.at;
    final end = forecastEnd.isAfter(horizon)
        ? horizon
        : (forecastEnd.isAfter(now) ? forecastEnd : now);
    final percent = window.percent!;
    final label = _GroupLabel('Last 7 days · ${window.label}');

    if (series.length < 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          label,
          Text(
            series.isEmpty
                ? 'No readings of ${window.label} this week yet — the chart '
                      'fills in as usage is checked.'
                : 'One reading of ${window.label} so far — the chart starts '
                      'with the next.',
            style: meta,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        label,
        _TightChartBox(
          width: width,
          height: _chartHeight,
          child: TimeSeriesChart(
            points: [
              for (final s in series) TimeSeriesPoint(s.recordedAt, s.percent),
            ],
            forecast: clipForecast(forecast, end),
            start: start,
            end: end,
            maxY: math.max(100, series.map((s) => s.percent).reduce(math.max)),
            color: usageSeverityColor(context, usageSeverityFor(percent)),
            guides: const [100],
            breakAfter: const Duration(hours: 1),
            height: _chartHeight,
            valueLabel: (v) => '${v.round()}%',
            timeLabel: (t) => formatResetClock(t, now),
            semanticsLabel: usageSeriesSummary(
              window.label,
              series,
              kUsageHistoryWindow,
            ),
          ),
        ),
      ],
    );
  }
}

/// A box of a fixed size that **answers intrinsic and dry-layout questions
/// itself** and hands its child that size as tight constraints.
///
/// [TimeSeriesChart] lays out through a LayoutBuilder, which cannot answer an
/// intrinsic or dry-layout question; a [MenuAnchor] asks them of everything in
/// its panel, and the answer failing was what closed the card as it opened.
/// A plain SizedBox forwards some of those questions to its child; this does
/// not, so the child is only ever laid out.
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
