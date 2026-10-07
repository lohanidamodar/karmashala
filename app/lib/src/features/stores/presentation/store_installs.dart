import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import 'stores_format.dart';

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The figure itself: `12.3K`, or the listing's band as it shows it, `10K+`.
String formatInstallFigure(InstallTotal total) => total.atLeast
    ? total.band ?? '${formatCompactCount(total.count)}+'
    : formatCompactCount(total.count);

/// A `2024-03` or `2021` period as people say it: `Mar 2024`, `2021`.
String formatInstallPeriod(String period) {
  final match = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(period);
  if (match == null) return period;
  final month = int.parse(match.group(2)!);
  if (month < 1 || month > 12) return period;
  return '${_monthNames[month - 1]} ${match.group(1)}';
}

/// What the count is, under the figure: `user installs since Mar 2024`,
/// `Play listing band`.
String describeInstallMeasure(InstallTotal total) {
  if (total.atLeast) return 'installs, Play listing band';
  final since = total.since;
  return since == null
      ? '${total.measure}, lifetime'
      : '${total.measure} since ${formatInstallPeriod(since)}';
}

/// Everything about the count, for a tooltip: the exact number, what it
/// counts, where from, and as of when; [readAt] is when it was read.
String describeInstallTotal(
  InstallTotal total,
  StoreKind store, {
  DateTime? readAt,
}) {
  if (total.atLeast) {
    final band = total.band ?? '${total.count}+';
    final note = total.note;
    return [
      '$band installs, the band ${store.label}\'s public listing shows: '
          'at least ${_grouped(total.count)}.',
      if (readAt != null) 'Listing read ${formatDay(readAt)}.',
      if (note != null && note.isNotEmpty) 'No exact count: $note',
    ].join('\n');
  }
  final through = total.through;
  return [
    '${_grouped(total.count)} ${describeInstallMeasure(total)}, from '
        '${store.label}\'s own reports.',
    if (through != null) 'Counted to ${formatReportDay(through)}.',
  ].join('\n');
}

/// `12,345`.
String _grouped(int value) {
  final digits = value.abs().toString();
  final out = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// An app's all-time installs on a card's store line: a compact figure, and
/// on hover what it counts and where it came from.
class AllTimeInstallsFigure extends StatelessWidget {
  const AllTimeInstallsFigure({
    required this.total,
    required this.store,
    this.readAt,
    super.key,
  });

  final InstallTotal total;
  final StoreKind store;
  final DateTime? readAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final figure = formatInstallFigure(total);
    return Tooltip(
      message: describeInstallTotal(total, store, readAt: readAt),
      child: Semantics(
        label: '$figure ${describeInstallMeasure(total)}',
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.downloadSimple,
                size: Chrome.iconAction,
                color: muted,
              ),
              const SizedBox(width: Insets.xxs),
              Text(
                figure,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
