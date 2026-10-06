import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_board.dart';
import '../application/overview_providers.dart';

/// The numbers above the Board: what needs you and the oldest wait, what
/// works, what is ready, failing checks, usage-limit hits and spend.
class OverviewStripBar extends ConsumerWidget {
  const OverviewStripBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strip = ref.watch(overviewStripProvider);
    final semantic = SemanticColors.of(context);
    final wait = strip.oldestWait;
    return Wrap(
      key: const ValueKey('overview-strip'),
      spacing: Insets.md,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Figure(
          text: [
            '${strip.needsYou} need you',
            if (wait != null && strip.needsYou > 0)
              'oldest ${compactAge(wait)}',
          ].join(' · '),
          color: strip.needsYou > 0 ? semantic.attention : null,
          strong: strip.needsYou > 0,
        ),
        if (strip.failed > 0)
          _Figure(text: '${strip.failed} failed', color: semantic.failure),
        _Figure(text: '${strip.working} working'),
        _Figure(text: '${strip.ready} ready'),
        if (strip.failingChecks > 0)
          _Figure(
            text: strip.failingChecks == 1
                ? '1 failing check'
                : '${strip.failingChecks} failing checks',
            color: semantic.failure,
          ),
        if (strip.usageLimitHits > 0)
          _Figure(
            text: strip.usageLimitHits == 1
                ? '1 usage limit hit'
                : '${strip.usageLimitHits} usage limit hits',
            color: semantic.attention,
          ),
        Tooltip(
          message:
              'What agents reported spending over their protocol (ACP), for '
              'sessions active today. CLI sessions report no cost.',
          child: _Figure(text: spendText(strip)),
        ),
      ],
    );
  }
}

/// "$0.42 today (ACP)", or "spend not recorded" when no agent reported one.
String spendText(OverviewStrip strip) {
  if (!strip.spendRecorded) return 'spend not recorded';
  final parts = [
    for (final MapEntry(key: currency, value: amount) in strip.spend.entries)
      switch (currency) {
        'USD' => '\$${amount.toStringAsFixed(2)}',
        '' => amount.toStringAsFixed(2),
        _ => '${amount.toStringAsFixed(2)} $currency',
      },
  ];
  return '${parts.join(' + ')} today (ACP)';
}

class _Figure extends StatelessWidget {
  const _Figure({required this.text, this.color, this.strong = false});

  final String text;
  final Color? color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        fontWeight: strong ? FontWeight.w600 : null,
      ),
    );
  }
}
