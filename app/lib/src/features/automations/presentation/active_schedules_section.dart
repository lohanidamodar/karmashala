import '../../workspaces/data/workspace_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/presentation/usage_chip.dart'
    show formatResetClock, formatUsageDuration;
import '../../sessions/application/session_providers.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import '../application/automation_providers.dart';
import '../application/scheduled_resume_providers.dart';
import '../application/unattended_preflight.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/schedules.dart';
import 'package:karmashala_automations/resumes.dart';
import 'minute_ticker.dart';

/// Everything that will fire on its own — armed automations and waiting
/// resumes — in one list at the top of Settings → Checkpoints and automations,
/// soonest first. The cards below still hold the detail; this answers "what is
/// coming".
class ActiveSchedulesSection extends ConsumerWidget {
  const ActiveSchedulesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final automations = ref
        .watch(automationsProvider)
        .where((a) => a.enabled)
        .toList();
    final resumes = ref.watch(liveScheduledResumesProvider);

    return SettingsSection(
      key: const ValueKey('active-schedules'),
      title: 'ACTIVE',
      child: automations.isEmpty && resumes.isEmpty
          ? const SettingsNote('Nothing is armed or waiting.')
          // One tick for the whole list: every row's countdown moves together.
          : MinuteTicker(
              builder: (context, now) {
                final rows = <({DateTime? at, Widget row})>[
                  for (final resume in resumes)
                    (
                      at: resume.fireAt,
                      row: _ResumeRow(
                        key: ValueKey('active-resume-${resume.id}'),
                        resume: resume,
                        now: now,
                      ),
                    ),
                  for (final automation in automations)
                    () {
                      final at = nextFireOf(automation, now: now.toUtc());
                      return (
                        at: at,
                        row: _AutomationRow(
                          key: ValueKey('active-automation-${automation.id}'),
                          automation: automation,
                          at: at,
                          now: now,
                        ),
                      );
                    }(),
                ];
                // Soonest first; one that cannot say when goes last.
                rows.sort((a, b) {
                  if (a.at == null || b.at == null) {
                    return (a.at == null ? 1 : 0) - (b.at == null ? 1 : 0);
                  }
                  return a.at!.compareTo(b.at!);
                });
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final entry in rows) entry.row],
                );
              },
            ),
    );
  }
}

/// When [automation] next fires, UTC, or null when it will not: a one-off
/// whose moment has passed, or a schedule this build cannot read.
DateTime? nextFireOf(Automation automation, {required DateTime now}) {
  if (!automation.isScheduled) return null;
  final schedule = automation.schedule;
  if (schedule.isOnce) {
    final at = schedule.firesAt!;
    return at.isAfter(now) ? at : null;
  }
  // An interval's next moment depends on when its last run finished, which is
  // the scheduler's to know; this list says "not due again" rather than
  // guessing at a time the timer is not actually armed for.
  if (schedule.isInterval) return null;
  return CronSchedule.parse(schedule.cron!)?.nextAfter(now);
}

class _AutomationRow extends ConsumerWidget {
  const _AutomationRow({
    required this.automation,
    required this.at,
    required this.now,
    super.key,
  });

  final Automation automation;
  final DateTime? at;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repository = ref
        .watch(workspaceDataProvider)
        .repository(automation.repositoryId);
    final refusal = ref.watch(automationRefusalProvider(automation.id));
    final when = at;
    return _ActiveRow(
      icon: AppIcons.robot,
      title: automation.name,
      detail: [
        repository?.name ?? 'a checkout that is no longer here',
        if (automation.trigger case final trigger?)
          'when a session ${trigger.kind.phrase}'
        else ...[
          ?automation.schedule.cron,
          if (automation.schedule.isInterval)
            'every ${describeGap(automation.schedule.gap!)} after each run',
        ],
      ].join(' · '),
      when: when == null
          ? (automation.isWebhook
                ? 'on a call'
                : automation.isEventDriven
                ? 'on event'
                : automation.schedule.isInterval
                ? 'after the next run'
                : 'not due again')
          : _describeWhen(when, now),
      // The gate's own words, on hover: the card below carries them in full.
      warning: refusal == null
          ? null
          : Tooltip(
              message: refusal.reason,
              child: Text(
                'Refused',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
    );
  }
}

class _ResumeRow extends ConsumerWidget {
  const _ResumeRow({required this.resume, required this.now, super.key});

  final ScheduledResume resume;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionsDataProvider).getById(resume.sessionId);
    return _ActiveRow(
      icon: AppIcons.clockCounterClockwise,
      title: 'Resume · ${session?.title ?? 'a session that is no longer here'}',
      detail: [
        resume.windowLabel == null
            ? 'at a time you chose'
            : 'the ${resume.windowLabel} window',
        if (resume.state != ScheduledResumeState.pending) resume.state.label,
      ].join(' · '),
      when: resume.state == ScheduledResumeState.firing
          ? 'now'
          : _describeWhen(resume.fireAt, now),
    );
  }
}

/// "14:05 · in 42m", from the same two formatters the resume cards use.
String _describeWhen(DateTime when, DateTime now) =>
    '${formatResetClock(when, now)} · in '
    '${formatUsageDuration(when.toLocal().difference(now))}';

class _ActiveRow extends StatelessWidget {
  const _ActiveRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.when,
    this.warning,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String when;
  final Widget? warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // A board row: ruled, a quiet glyph, the name in the row label's hand.
    return SettingsRuled(
      child: Row(
        children: [
          Icon(
            icon,
            size: Chrome.iconSmall,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SettingsStyles.rowLabel(context),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(detail, style: muted, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (warning != null) ...[warning!, const SizedBox(width: Insets.sm)],
          Text(when, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
