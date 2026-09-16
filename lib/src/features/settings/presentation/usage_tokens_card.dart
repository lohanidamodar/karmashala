import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/session_token_totals.dart';
import 'settings_notice.dart';
import 'settings_section.dart';

/// Tokens by project and by agent, over the sessions active in the last week.
/// Counted only when asked: it reads every recent session's own file.
class UsageTokensCard extends ConsumerStatefulWidget {
  const UsageTokensCard({super.key});

  @override
  ConsumerState<UsageTokensCard> createState() => _UsageTokensCardState();
}

class _UsageTokensCardState extends ConsumerState<UsageTokensCard> {
  bool _asked = false;

  void _count() {
    if (_asked) ref.invalidate(tokenTotalsProvider);
    setState(() => _asked = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final totals = _asked ? ref.watch(tokenTotalsProvider) : null;
    final loading = totals?.isLoading ?? false;
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Tokens in the last 7 days',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (loading)
                const InlineSpinner(semanticsLabel: 'Counting tokens')
              else
                TextButton.icon(
                  onPressed: _count,
                  icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.iconAction),
                  label: Text(_asked ? 'Count again' : 'Count tokens'),
                ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          ...switch (totals) {
            null => [
              Text(
                'Adds up the tokens each session’s own files recorded, by '
                'project and by agent. Reads those files, so it runs only when '
                'you ask.',
                style: muted,
              ),
            ],
            AsyncValue(:final error?) => [
              SettingsNotice(
                tone: SettingsNoticeTone.danger,
                message: 'Could not count tokens',
                detail: '$error',
              ),
            ],
            AsyncValue(:final value?) => _results(context, value, muted),
            _ => [Text('Reading session files…', style: muted)],
          },
        ],
      ),
    );
  }

  List<Widget> _results(
    BuildContext context,
    TokenTotals totals,
    TextStyle? muted,
  ) {
    final theme = Theme.of(context);
    final colour = SemanticColors.of(context).working;
    final heading = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
    );
    if (totals.isEmpty) {
      return [
        Text(
          totals.uncounted == 0
              ? 'No session was active in the last 7 days.'
              : 'No session active in the last 7 days recorded token counts.',
          style: muted,
        ),
      ];
    }
    List<BarDatum> bars(List<(String, int)> entries) => [
      for (final (label, tokens) in entries)
        BarDatum(
          label: label,
          value: tokens.toDouble(),
          valueLabel: formatTokenCount(tokens),
        ),
    ];
    return [
      Text(
        '${formatTokenCount(totals.total)} tokens across ${totals.counted} '
        '${totals.counted == 1 ? 'session' : 'sessions'}',
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: Insets.sm),
      Text('By project', style: heading),
      RankedBars(bars: bars(totals.byProject), color: colour),
      const SizedBox(height: Insets.sm),
      Text('By agent', style: heading),
      RankedBars(bars: bars(totals.byAgent), color: colour),
      const SizedBox(height: Insets.xs),
      Text(
        'Whole-session totals, cache reads included, for sessions last active '
        'in the period'
        '${totals.uncounted == 0 ? '' : ' · ${totals.uncounted} recorded no counts'}'
        '.',
        style: muted,
      ),
    ];
  }
}
