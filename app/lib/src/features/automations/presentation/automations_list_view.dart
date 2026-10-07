import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../terminal/presentation/session_status.dart' show describeAge;

import '../application/automation_draft.dart';
import '../application/automation_editor_state.dart';
import '../application/automation_providers.dart';
import '../application/automation_templates.dart';
import 'automation_editor.dart';
import 'automation_run_actions.dart';
import 'automation_run_status.dart';
import 'project_checks_section.dart';

/// The Automations list: templates first, then every automation by checkout.
class AutomationsListView extends ConsumerWidget {
  const AutomationsListView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(automationEditorProvider);
    if (editing != null) {
      return AutomationEditor(
        key: ValueKey('editor-${editing.generation}'),
        initial: editing.draft,
      );
    }
    final automations = ref.watch(automationsProvider);
    final repositories = ref.watch(automationCheckoutsProvider);
    final byCheckout = <String, List<Automation>>{};
    for (final automation in automations) {
      (byCheckout[automation.repositoryId] ??= []).add(automation);
    }
    return ListView(
      key: const ValueKey('automations-list'),
      padding: const EdgeInsets.all(Insets.lg),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const EyebrowLabel('Start from a template'),
                const SizedBox(height: Insets.sm),
                _Templates(repositories: repositories),
                const SizedBox(height: Insets.xl),
                if (automations.isEmpty)
                  const PanePlaceholder(
                    icon: AppIcons.lightning,
                    message:
                        'Nothing set up yet. Start from a template, or make a '
                        'new automation.',
                  )
                else
                  for (final entry in byCheckout.entries)
                    _CheckoutGroup(
                      repository: repositories
                          .where((r) => r.id == entry.key)
                          .firstOrNull,
                      automations: entry.value,
                    ),
                const SizedBox(height: Insets.lg),
                const ProjectChecksSection(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens a new, empty automation in [repositoryId] — or, with [template],
/// that template's.
void newAutomation(
  WidgetRef ref, {
  String? repositoryId,
  AutomationTemplate? template,
}) {
  final checkout =
      repositoryId ?? ref.read(automationCheckoutsProvider).firstOrNull?.id;
  ref
      .read(automationEditorProvider.notifier)
      .open(
        template?.build(checkout) ?? AutomationDraft(repositoryId: checkout),
      );
}

/// The glyph of what starts an automation.
IconData triggerIcon(DraftTrigger trigger) => switch (trigger) {
  DraftTrigger.schedule => AppIcons.clock,
  DraftTrigger.event => AppIcons.lightning,
  DraftTrigger.webhook => AppIcons.webhooksLogo,
  DraftTrigger.github => AppIcons.gitBranch,
  DraftTrigger.once => AppIcons.calendarBlank,
};

DraftTrigger triggerOf(Automation a) => a.github != null
    ? DraftTrigger.github
    : a.webhook != null
    ? DraftTrigger.webhook
    : a.trigger != null
    ? DraftTrigger.event
    : a.schedule.isOnce
    ? DraftTrigger.once
    : DraftTrigger.schedule;

class _Templates extends ConsumerWidget {
  const _Templates({required this.repositories});

  final List<Repository> repositories;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 720
          ? 3
          : constraints.maxWidth >= 440
          ? 2
          : 1;
      final width =
          (constraints.maxWidth - Insets.sm * (columns - 1)) / columns;
      return Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.sm,
        children: [
          for (final template in kAutomationTemplates)
            SizedBox(
              width: width,
              child: _TemplateCard(
                template: template,
                onTap: () => newAutomation(ref, template: template),
              ),
            ),
        ],
      );
    },
  );
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({required this.template, required this.onTap});

  final AutomationTemplate template;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        key: ValueKey('template-${template.title}'),
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    triggerIcon(template.trigger),
                    size: Touch.iconSmall,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: Insets.xs),
                  Flexible(
                    child: Text(
                      template.trigger.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.xs),
              Text(template.title, style: theme.textTheme.titleSmall),
              const SizedBox(height: Insets.xxs),
              Text(
                template.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckoutGroup extends ConsumerWidget {
  const _CheckoutGroup({required this.repository, required this.automations});

  final Repository? repository;
  final List<Automation> automations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  repository?.name ?? 'A checkout that is gone',
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Insets.xs),
              Text('· ${automations.length}', style: theme.textTheme.bodySmall),
              const Spacer(),
              if (repository case final repository?)
                TextButton.icon(
                  icon: const Icon(AppIcons.plus),
                  label: Text('New in ${repository.name}'),
                  onPressed: () =>
                      newAutomation(ref, repositoryId: repository.id),
                ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(
              children: [
                for (final (i, automation) in automations.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  AutomationRow(
                    key: ValueKey(automation.id),
                    automation: automation,
                    checkout: repository?.name ?? 'its checkout',
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One automation: what it does in one line, how it last went, when it next
/// runs, its switch and its menu.
class AutomationRow extends ConsumerWidget {
  const AutomationRow({
    required this.automation,
    required this.checkout,
    super.key,
  });

  final Automation automation;
  final String checkout;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (context, constraints) => _row(
      context,
      ref,
      wide: !WidthClass.of(
        constraints.maxWidth,
        textScaler: MediaQuery.textScalerOf(context),
      ).isCompact,
    ),
  );

  Widget _row(BuildContext context, WidgetRef ref, {required bool wide}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.watch(clockProvider).nowUtc();
    final runs = ref.watch(automationRunsProvider(automation.id));
    final last = runs.firstOrNull;
    final checks = last == null
        ? const <AutomationCheckVerdict>[]
        : ref.watch(automationRunChecksProvider(last.id));
    final registry = ref.watch(agentRegistryProvider);
    final installation = ref
        .watch(agentInstallationsDataProvider)
        .getById(automation.agentInstallationId);
    final summary = automationWords(
      automation,
      checkout: checkout,
      agent: installation == null
          ? 'an agent'
          : registry.displayNameFor(installation.agentId),
      now: now,
    );
    final lastRun = last == null
        ? 'Never run'
        : '${runOutcome(last, checks).label} '
              '${describeAge(last.firedAt, now: now)}';
    final next = nextRunWords(automation, now: now);
    final status = Text(
      wide ? lastRun : '$lastRun · $next',
      style: theme.textTheme.bodySmall?.copyWith(
        color: last == null
            ? scheme.onSurfaceVariant
            : runOutcomeColor(context, runOutcome(last, checks)),
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return InkWell(
      onTap: () => ref.read(automationEditorProvider.notifier).edit(automation),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Row(
          children: [
            Tooltip(
              message: triggerOf(automation).label,
              child: Icon(
                triggerIcon(triggerOf(automation)),
                color: scheme.tertiary,
                size: Touch.icon,
              ),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    automation.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    summary,
                    key: ValueKey('automation-summary-${automation.id}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!wide) status,
                ],
              ),
            ),
            if (wide) ...[
              const SizedBox(width: Insets.md),
              SizedBox(
                width: Touch.target * 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    status,
                    Text(
                      next,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
            Switch(
              value: automation.enabled,
              onChanged: (on) => ref
                  .read(automationControllerProvider)
                  .setEnabled(automation.id, enabled: on),
            ),
            _RowMenu(automation: automation),
          ],
        ),
      ),
    );
  }
}

enum _RowAction { runNow, edit, duplicate, runs, delete }

class _RowMenu extends ConsumerWidget {
  const _RowMenu({required this.automation});

  final Automation automation;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      PopupMenuButton<_RowAction>(
        key: ValueKey('automation-menu-${automation.id}'),
        tooltip: 'More for ${automation.name}',
        icon: const Icon(AppIcons.dotsThree),
        onSelected: (action) {
          switch (action) {
            case _RowAction.runNow:
              runAutomationNow(context, ref, automation);
            case _RowAction.edit:
              ref.read(automationEditorProvider.notifier).edit(automation);
            case _RowAction.duplicate:
              // Opened to create, not saved: saving a copy is arming it.
              ref
                  .read(automationEditorProvider.notifier)
                  .open(AutomationDraft.from(automation).asNewCopy());
            case _RowAction.runs:
              showRunsOf(ref, automation.id);
            case _RowAction.delete:
              confirmDeleteAutomation(context, ref, automation);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: _RowAction.runNow, child: Text('Run now')),
          PopupMenuItem(value: _RowAction.edit, child: Text('Edit')),
          PopupMenuItem(value: _RowAction.duplicate, child: Text('Duplicate')),
          PopupMenuItem(value: _RowAction.runs, child: Text('See its runs')),
          PopupMenuItem(value: _RowAction.delete, child: Text('Delete…')),
        ],
      );
}
