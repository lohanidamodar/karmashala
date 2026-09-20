import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_providers.dart';
import 'companion_chrome.dart';
import 'companion_states.dart';

/// Where a quota stops being background information — the desktop's pair.
const double _warnAt = 80;
const double _criticalAt = 95;

/// Every agent account's usage limits, as the desktop last read them: a card
/// per account, a meter per window, the pace, and the last day as a line.
class UsageScreen extends ConsumerWidget {
  const UsageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gateway = ref.read(companionGatewayProvider);
    // Asked in words before the host is: a phone paired before usage existed
    // was never granted it, and pairing again is the only way to be.
    if (!gateway.capabilities.has(Capability.viewUsage)) {
      return const CompanionNotice(
        icon: AppIcons.lockSimple,
        title: 'Usage was not granted to this phone',
        body:
            'This phone was paired before usage limits could be shared. Pair '
            'it again from the desktop — Settings › Remote access — and leave '
            '"See usage limits" on.',
      );
    }
    final usage = ref.watch(companionUsageProvider);
    return companionAsync(
      usage,
      loading: () => const CompanionSkeletonList(rows: 2, lines: 3),
      error: (error) => CompanionNotice.failure(
        error: error,
        onRetry: () => ref.invalidate(companionUsageProvider),
      ),
      data: (snapshot) => RefreshIndicator(
        onRefresh: () => ref.refresh(companionUsageProvider.future),
        child: snapshot.accounts.isEmpty
            ? ListView(
                children: const [
                  CompanionNotice(
                    icon: AppIcons.info,
                    title: 'No accounts to show',
                    body:
                        'Your desktop has no Claude Code, Codex or Antigravity '
                        'installed that it can read limits for.',
                  ),
                ],
              )
            : ListView(
                padding: companionListInsets(
                  context,
                  const EdgeInsets.fromLTRB(
                    Insets.md,
                    Insets.sm,
                    Insets.md,
                    Insets.xl,
                  ),
                ),
                children: [
                  for (final account in snapshot.accounts)
                    UsageAccountCard(
                      account: account,
                      now: snapshot.observedAt,
                    ),
                ],
              ),
      ),
    );
  }
}

/// One account: who, where, how fresh, and each of its windows.
class UsageAccountCard extends StatelessWidget {
  const UsageAccountCard({required this.account, required this.now, super.key});

  final RemoteUsageAccount account;

  /// The host's clock when it answered — the reading's age and every reset
  /// are counted from it, so a phone whose clock drifts still agrees.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final readAt = account.readAt;
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.md),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: density.padX,
          vertical: density.padY,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${account.agentName} · ${account.environment}',
              style: theme.textTheme.titleSmall,
            ),
            if (account.email != null)
              Text(
                account.email!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            Text(
              readAt == null
                  ? 'Not read yet'
                  : 'Read ${describeAge(now.difference(readAt))}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (account.failure != null) ...[
              SizedBox(height: density.lineGap),
              Text(
                account.failure!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: SemanticColors.of(context).attention,
                ),
              ),
            ],
            for (final window in account.windows) ...[
              SizedBox(height: density.lineGap * 2),
              UsageWindowRow(window: window, now: now),
            ],
          ],
        ),
      ),
    );
  }
}

/// One window: its meter, how much is used, when it resets, how it is being
/// spent, and the last day as a line.
class UsageWindowRow extends StatelessWidget {
  const UsageWindowRow({required this.window, required this.now, super.key});

  final RemoteUsageWindow window;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final percent = window.percent;
    final colour = switch (percent) {
      null => scheme.onSurfaceVariant,
      >= _criticalAt => semantic.failure,
      >= _warnAt => semantic.attention,
      _ => semantic.idle,
    };
    final resets = window.resetsAt;
    final pace = usagePaceSentence(window, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(window.label, style: theme.textTheme.bodyMedium),
            ),
            Text(
              percent == null ? 'not measured' : '${percent.round()}% used',
              style: theme.textTheme.bodyMedium?.copyWith(color: colour),
            ),
          ],
        ),
        if (percent != null) ...[
          const SizedBox(height: Insets.xs),
          LinearMeter(
            value: (percent / 100).clamp(0.0, 1.0),
            color: colour,
            semanticsLabel: '${window.label}: ${percent.round()}% used',
          ),
        ],
        const SizedBox(height: Insets.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                [
                  if (resets != null) 'Resets ${_resetPhrase(resets, now)}',
                  ?pace,
                ].join(' · '),
                style: theme.textTheme.labelSmall?.copyWith(
                  color:
                      window.pace == RemoteUsagePace.overPace ||
                          window.pace == RemoteUsagePace.spent
                      ? semantic.attention
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (window.samples.length > 1) ...[
              const SizedBox(width: Insets.sm),
              Sparkline(
                values: [for (final s in window.samples) s.percent],
                color: colour,
                maxValue: 100,
                width: 72,
                semanticsLabel: '${window.label} over the last day',
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// How a window is being spent, in words, or null when the desktop could not
/// judge it.
String? usagePaceSentence(RemoteUsageWindow window, DateTime now) =>
    switch (window.pace) {
      RemoteUsagePace.unknown => null,
      RemoteUsagePace.onPace => 'within pace',
      RemoteUsagePace.aheadOfPace => 'slightly ahead of pace',
      RemoteUsagePace.spent => 'limit reached',
      RemoteUsagePace.overPace => switch (window.limitAt) {
        final at? when at.isAfter(now) =>
          'over pace — runs out in ${_span(at.difference(now))}',
        _ => 'over pace',
      },
    };

String _resetPhrase(DateTime resets, DateTime now) =>
    resets.isAfter(now) ? 'in ${_span(resets.difference(now))}' : 'now';

/// "2h11m", "3d 4h", "12m".
String _span(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h${d.inMinutes % 60}m';
  return '${d.inMinutes.clamp(1, 59)}m';
}
