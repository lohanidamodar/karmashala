import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../settings/presentation/settings_section.dart';
import '../../terminal/presentation/session_status.dart' show describeAge;
import '../../verification/domain/verification_run.dart';
import '../application/automation_providers.dart';
import '../application/unattended_preflight.dart';
import '../domain/automation.dart';
import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/cron_schedule.dart';
import '../../env_secrets/presentation/settings_item_card.dart';
import 'automation_dialog.dart';
import 'automation_undo_dialog.dart';
import 'project_checks_section.dart';

/// Settings → Automations: where a run is armed, paused, deleted, and where
/// "did it run last night" is answered. Arming happens here and nowhere else.
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
      padding: EdgeInsets.symmetric(horizontal: Insets.sm, vertical: Insets.xs),
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

    return SettingsItemCard(
      title: Wrap(
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
      details: [
        Text(
          repository?.name ?? 'a checkout that is no longer here',
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: Insets.sm),
        _Line(
          label: 'Runs',
          value: describeSchedule(automation, now: now),
        ),
        _Line(label: 'Agent', value: agentName),
        _Line(label: 'Prompt', value: automation.prompt),
        if (refusal != null) ...[
          const SizedBox(height: Insets.sm),
          // The gate's own words; not dismissable, since it still refuses.
          DesktopErrorBanner(refusal.reason),
        ],
      ],
      actions: [
        TextButton(
          onPressed: () => ref
              .read(automationControllerProvider)
              .setEnabled(automation.id, enabled: !automation.enabled),
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
          onPressed: () => _confirmDelete(context, ref, automation),
          child: const Text('Delete'),
        ),
      ],
      footer: [
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
    );
  }
}

/// Asks first: a deleted automation is gone, schedule, prompt and all, and
/// re-arming it is the whole authorisation again.
Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  Automation automation,
) async {
  final controller = ref.read(automationControllerProvider);
  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete ${automation.name}?',
    message:
        'It will not fire again, and its schedule and prompt are forgotten. '
        'To stop it for now and keep it, pause it instead.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (confirmed) controller.delete(automation.id);
}

/// What the card says about when this fires. Never "next run in 18 hours" for a
/// schedule this build cannot read, and a paused one says it is paused.
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
    return LabeledValueRow(
      label: label,
      labelWidth: 62,
      labelStyle: theme.textTheme.bodySmall,
      padding: const EdgeInsets.only(top: 1),
      value: Text(
        value,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
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
