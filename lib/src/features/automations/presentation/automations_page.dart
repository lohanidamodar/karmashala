import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../settings/presentation/settings_section.dart';
import '../../terminal/presentation/session_status.dart' show describeAge;
import '../../verification/domain/verification_run.dart';
import '../application/automation_providers.dart';
import '../application/unattended_preflight.dart';
import '../domain/automation.dart';
import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/cron_schedule.dart';
import 'automation_dialog.dart';
import 'automation_undo_dialog.dart';
import 'project_checks_section.dart';

/// Settings → Automations: where an agent run is armed, paused, deleted, and
/// where "did it run last night" is answered.
///
/// **A Settings page rather than a side-panel surface.** A surface is a thing
/// you work *in* beside a session; an automation is configuration you set once
/// and then read the record of, which is the shape Worktrees and Environments
/// already have. What earns its place beside the settings is the run list: the
/// person who armed a nightly sweep comes back to this page to find out
/// whether it ran, so the record and the switch that made it are on one card.
///
/// **Arming is a human action here and nowhere else.** No MCP tool serves it —
/// `mcp_tool_catalogue.dart` says so and a test holds the served names to it.
class AutomationsPage extends ConsumerWidget {
  const AutomationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final automations = ref.watch(automationsProvider);
    final repositories = ref.watch(repositoryDaoProvider).getAll();
    // Watched so a project added or rescanned while this is open reaches the
    // "arm one" list without the page being reopened.
    ref.watch(projectsControllerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'AUTOMATIONS',
          trailing: repositories.isEmpty
              ? null
              : _ArmButton(checkouts: repositories),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'An automation starts an agent on a schedule, in a checkout\'s '
                'own environment, with nobody watching. Arming one is you '
                'authorising that run in advance — which is why it happens '
                'here and cannot be asked for by an agent.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                'It holds because Karmashala refuses to fire when the '
                'conditions for unsupervised work are absent, and says which '
                'one. A refusal is checked again at the moment it would fire, '
                'not only when you armed it.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.md),
              if (automations.isEmpty)
                Text(
                  repositories.isEmpty
                      ? 'No checkouts have been scanned yet.'
                      : 'Nothing is armed.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                for (final automation in automations)
                  AutomationCard(
                    key: ValueKey(automation.id),
                    automation: automation,
                  ),
            ],
          ),
        ),
        const ProjectChecksSection(),
      ],
    );
  }
}

/// Arms a new automation in a checkout the workspace knows about.
class _ArmButton extends ConsumerWidget {
  const _ArmButton({required this.checkouts});

  final List<Repository> checkouts;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    tooltip: 'Arm an automation',
    onSelected: (id) => AutomationDialog.show(
      context,
      repository: checkouts.firstWhere((r) => r.id == id),
    ),
    itemBuilder: (_) => [
      for (final repository in checkouts)
        PopupMenuItem(
          value: repository.id,
          child: Text('${repository.name}  ·  ${repository.path.path}'),
        ),
    ],
    child: const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.plus),
          SizedBox(width: Insets.xs),
          Text('Arm an automation'),
        ],
      ),
    ),
  );
}

/// One automation: what it will do, whether it can, and what it has done.
class AutomationCard extends ConsumerWidget {
  const AutomationCard({required this.automation, super.key});

  final Automation automation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repository = ref
        .watch(repositoryDaoProvider)
        .getById(automation.repositoryId);
    final environment = repository == null
        ? null
        : ref
              .watch(executionEnvironmentDaoProvider)
              .getById(repository.path.environmentId);
    final refusal = ref.watch(automationRefusalProvider(automation.id));
    final runs = ref.watch(automationRunsProvider(automation.id));
    final now = ref.watch(clockProvider).nowUtc();
    final installation = ref
        .watch(agentInstallationDaoProvider)
        .getById(automation.agentInstallationId);
    final agentName = installation == null
        ? 'an agent that is no longer installed'
        : ref.watch(agentRegistryProvider).displayNameFor(installation.agentId);

    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Insets.sm,
            children: [
              Text(automation.name, style: theme.textTheme.bodyMedium),
              if (!automation.enabled)
                Text('Paused', style: theme.textTheme.bodySmall),
              Text(
                _environmentLabel(environment?.kind, environment?.name),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          Text(
            repository?.name ?? 'a checkout that is no longer here',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Insets.sm),
          _Line(label: 'Runs', value: describeSchedule(automation, now: now)),
          _Line(label: 'Agent', value: agentName),
          _Line(label: 'Prompt', value: automation.prompt),
          if (refusal != null) ...[
            const SizedBox(height: Insets.sm),
            _Refusal(reason: refusal.reason),
          ],
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.xs,
            children: [
              TextButton(
                onPressed: () => ref
                    .read(automationControllerProvider)
                    .setEnabled(
                      automation.id,
                      enabled: !automation.enabled,
                    ),
                child: Text(automation.enabled ? 'Pause' : 'Resume'),
              ),
              TextButton(
                onPressed: () => AutomationDialog.show(
                  context,
                  repository: repository,
                  existing: automation,
                ),
                child: const Text('Edit'),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(automationControllerProvider).delete(automation.id),
                child: const Text('Delete'),
              ),
            ],
          ),
          if (runs.isEmpty)
            Text(
              'It has not run yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else
            for (final run in runs.take(6))
              _RunLine(key: ValueKey(run.id), run: run, now: now),
        ],
      ),
    );
  }
}

/// What the card says about when this fires, and when it next will.
///
/// **Never "next run in 18 hours" for a schedule this build cannot read.** An
/// unparsable expression says so, and a paused automation says it is paused
/// rather than naming a time it will not keep.
String describeSchedule(Automation automation, {required DateTime now}) {
  final schedule = automation.schedule;
  if (schedule.isOnce) {
    final at = schedule.firesAt!.toLocal();
    if (!automation.enabled) return 'Once, at $at — paused';
    return at.isAfter(now.toLocal()) ? 'Once, at $at' : 'Once, at $at — passed';
  }
  final cron = CronSchedule.parse(schedule.cron!);
  if (cron == null) {
    return '"${schedule.cron}" — this build cannot read that schedule, so '
        'nothing is due';
  }
  if (!automation.enabled) return '${schedule.cron} — paused';
  final next = cron.nextAfter(now);
  if (next == null) return '${schedule.cron} — never comes round';
  return '${schedule.cron} — next ${next.toLocal()}';
}

/// Why this automation would be refused, in the gate's own words.
class _Refusal extends StatelessWidget {
  const _Refusal({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warning, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One occurrence, with its verdict, its age and its reason.
class _RunLine extends ConsumerWidget {
  const _RunLine({required this.run, required this.now, super.key});

  final AutomationRun run;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = switch (run.state) {
      AutomationRunState.finished => scheme.onSurfaceVariant,
      AutomationRunState.running => scheme.primary,
      AutomationRunState.queued => scheme.onSurfaceVariant,
      AutomationRunState.failed || AutomationRunState.missed => scheme.error,
      AutomationRunState.unrecognised => scheme.onSurfaceVariant,
    };
    // Every reading carries its age (§19), and a run is dated by when it was
    // *due* as well as by when the row was written — the two differ for a miss.
    final age = describeAge(run.firedAt, now: now);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                run.state.label,
                style: theme.textTheme.bodySmall?.copyWith(color: colour),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  'due ${run.scheduledFor.toLocal()} · $age',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (run.state == AutomationRunState.finished ||
                  run.state == AutomationRunState.failed)
                TextButton(
                  onPressed: () => AutomationUndoDialog.show(context, run: run),
                  child: const Text('Undo…'),
                ),
            ],
          ),
          if (run.reason.isNotEmpty)
            Text(
              run.reason,
              style: theme.textTheme.bodySmall?.copyWith(color: colour),
            ),
          if (!run.state.isLive) _checks(context, ref),
        ],
      ),
    );
  }

  /// What the checkout's own checks said about the work this run left — one
  /// summary line, then a line per check with its verdict and its age.
  Widget _checks(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final checks = ref.watch(automationRunChecksProvider(run.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          describeAutomationChecks(checks, observedAt: run.checksObservedAt),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        for (final check in checks)
          Text(
            '${check.verdict.label} · ${check.name} · '
            '${describeAge(check.checkedAt, now: now)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: switch (check.verdict) {
                VerificationVerdict.pass => scheme.onSurfaceVariant,
                VerificationVerdict.fail => scheme.error,
                VerificationVerdict.inconclusive => scheme.onSurfaceVariant,
              },
            ),
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _environmentLabel(EnvironmentKind? kind, String? name) => switch (kind) {
  EnvironmentKind.wsl => 'WSL · ${name ?? 'distro'}',
  EnvironmentKind.ssh => 'SSH · ${name ?? 'remote'}',
  EnvironmentKind.windowsNative => 'Windows',
  EnvironmentKind.localPosix => name ?? 'this machine',
  null => 'environment not recorded',
};
