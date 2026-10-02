import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../../sessions/presentation/hand_to_session.dart';
import '../application/store_groups.dart';
import '../application/store_prompts.dart';
import 'store_badges.dart';
import 'stores_format.dart';

/// Whether any of [group]'s stores reported crash and ANR clusters, or said
/// why it could not.
bool hasErrorIssues(StoreAppGroup group) =>
    group.entries.any((entry) => entry.snapshot?.errorIssues != null);

/// The most reported crash and ANR clusters, each one able to start a session
/// with its sample stack trace.
class StoreErrorIssuesSection extends ConsumerWidget {
  const StoreErrorIssuesSection({required this.group, super.key});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final now = ref.watch(clockProvider).nowUtc();
    final children = <Widget>[];
    for (final entry in group.entries) {
      switch (entry.snapshot?.errorIssues) {
        case null:
          break;
        case final ReadingMissing<List<StoreErrorIssue>> missing:
          children.add(
            MissingReadingLine(
              what: '${entry.app.store.label} crash clusters',
              reading: missing,
            ),
          );
        case ReadingValue(:final value) when value.isEmpty:
          children.add(
            Text('No crashes or ANRs in the last 28 days.', style: muted),
          );
        case ReadingValue(:final value):
          for (final issue in value) {
            children.add(
              _IssueRow(app: entry.app, issue: issue, now: now, muted: muted),
            );
          }
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, child) in children.indexed) ...[
              if (i > 0) const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                child: child,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({
    required this.app,
    required this.issue,
    required this.now,
    required this.muted,
  });

  final StoreApp app;
  final StoreErrorIssue issue;
  final DateTime now;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      issue.kind.label,
      if (issue.reportCount case final count?)
        '$count ${count == 1 ? 'report' : 'reports'}',
      if (issue.distinctUsers case final users?)
        '$users ${users == 1 ? 'user' : 'users'}',
      if (issue.lastVersionCode case final code?) 'last in build $code',
      if (issue.lastSeen case final at?) formatShortDay(at, now),
      if (issue.sampleTrace != null) 'stack trace read',
    ].join(' · ');
    final headline = issue.cause.isNotEmpty ? issue.cause : issue.kind.label;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                headline,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (issue.location.isNotEmpty) ...[
                const SizedBox(height: 2),
                SelectableText(
                  issue.location,
                  style: MonoStyles.body.copyWith(color: muted?.color),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                meta,
                style: muted?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Insets.sm),
        HandToSessionButton(
          label: 'Start a session from this crash',
          dense: true,
          title: '${issue.kind.label}: ${app.name}',
          prompt: () => errorIssuePrompt(app, issue),
        ),
      ],
    );
  }
}
