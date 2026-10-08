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
import 'proposal_actions.dart';
import 'turn_on_confirm_dialog.dart' show turnOnAutomation;

/// The narrowest an automation or template card is laid out, at 1x text.
const double kAutomationCardMinWidth = 360;

/// The most cards a row holds, however wide the tab.
const int kAutomationGridMaxColumns = 3;

/// How many cards fit across [width] under [textScaler]: one on a phone, two
/// or three on a desktop — a card grows with its text, so 1.6x text fits
/// fewer.
int automationGridColumns(double width, TextScaler textScaler) {
  final card = WidthClass.scaleBreakpoint(kAutomationCardMinWidth, textScaler);
  final fit = ((width + Insets.md) / (card + Insets.md)).floor();
  return fit.clamp(1, kAutomationGridMaxColumns);
}

/// The Automations list: every automation as a card, grouped by checkout, and
/// the templates — open while there is nothing, folded once there is.
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
        const ProposalsNotice(),
        if (automations.isEmpty) ...[
          const PanePlaceholder(
            icon: AppIcons.lightning,
            message:
                'Nothing set up yet. Start from a template, or make a new '
                'automation.',
          ),
          const SizedBox(height: Insets.lg),
          const EyebrowLabel('Start from a template'),
          const SizedBox(height: Insets.sm),
          const _Templates(),
        ] else ...[
          for (final entry in byCheckout.entries)
            _CheckoutGroup(
              repository: repositories
                  .where((r) => r.id == entry.key)
                  .firstOrNull,
              automations: entry.value,
            ),
          const _FoldedTemplates(),
        ],
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

/// [count] cells in [automationGridColumns] columns, each row as tall as its
/// tallest card and as wide as the grid.
class AutomationGrid extends StatelessWidget {
  const AutomationGrid({required this.count, required this.cell, super.key});

  final int count;
  final Widget Function(int index) cell;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = automationGridColumns(constraints.maxWidth, scaler);
        return Column(
          key: ValueKey('automation-grid-$columns'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var start = 0; start < count; start += columns)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = start; i < start + columns; i++) ...[
                        if (i > start) const SizedBox(width: Insets.md),
                        Expanded(
                          child: i < count ? cell(i) : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Templates extends ConsumerWidget {
  const _Templates();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AutomationGrid(
    count: kAutomationTemplates.length,
    cell: (i) => _TemplateCard(
      template: kAutomationTemplates[i],
      onTap: () => newAutomation(ref, template: kAutomationTemplates[i]),
    ),
  );
}

/// The templates behind one line, once there are automations to look at.
class _FoldedTemplates extends StatefulWidget {
  const _FoldedTemplates();

  @override
  State<_FoldedTemplates> createState() => _FoldedTemplatesState();
}

class _FoldedTemplatesState extends State<_FoldedTemplates> {
  var _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const ValueKey('templates-fold'),
          icon: Icon(_open ? AppIcons.caretUp : AppIcons.caretDown),
          label: const Text('Start from a template'),
          onPressed: () => setState(() => _open = !_open),
        ),
      ),
      if (_open) ...[const SizedBox(height: Insets.sm), const _Templates()],
    ],
  );
}

/// The rounded, outlined surface every card on the tab shares.
class _CardSurface extends StatelessWidget {
  const _CardSurface({required this.child, required this.onTap, super.key});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(Insets.md), child: child),
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({required this.template, required this.onTap});

  final AutomationTemplate template;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _CardSurface(
      key: ValueKey('template-${template.title}'),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: template.trigger.label,
            child: Icon(
              triggerIcon(template.trigger),
              size: Touch.icon,
              color: scheme.tertiary,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  template.title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  template.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
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
    final name = repository?.name ?? 'A checkout that is gone';
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Insets.xs),
              Text('· ${automations.length}', style: theme.textTheme.bodySmall),
              const Spacer(),
              if (repository case final repository?)
                IconButton(
                  key: ValueKey('automation-new-in-${repository.id}'),
                  tooltip: 'New automation in ${repository.name}',
                  icon: const Icon(AppIcons.plus),
                  onPressed: () =>
                      newAutomation(ref, repositoryId: repository.id),
                ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          AutomationGrid(
            count: automations.length,
            cell: (i) => AutomationCard(
              key: ValueKey(automations[i].id),
              automation: automations[i],
              checkout: repository?.name ?? 'its checkout',
            ),
          ),
        ],
      ),
    );
  }
}

/// One automation: its kind, name, what it does in plain words, how it last
/// went, when it next runs, its switch and its menu.
class AutomationCard extends ConsumerWidget {
  const AutomationCard({
    required this.automation,
    required this.checkout,
    super.key,
  });

  final Automation automation;
  final String checkout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final small = theme.textTheme.bodySmall;
    return _CardSurface(
      onTap: () => ref.read(automationEditorProvider.notifier).edit(automation),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Tooltip(
                message: triggerOf(automation).label,
                child: Icon(
                  triggerIcon(triggerOf(automation)),
                  color: scheme.tertiary,
                  size: Touch.icon,
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  automation.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Switch(
                value: automation.enabled,
                onChanged: (on) => on
                    ? turnOnAutomation(context, ref, automation)
                    : ref
                          .read(automationControllerProvider)
                          .setEnabled(automation.id, enabled: false),
              ),
              _CardMenu(automation: automation),
            ],
          ),
          Text(
            summary,
            key: ValueKey('automation-summary-${automation.id}'),
            style: small?.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const Spacer(),
          const SizedBox(height: Insets.sm),
          Text(
            lastRun,
            style: small?.copyWith(
              color: last == null
                  ? scheme.onSurfaceVariant
                  : runOutcomeColor(context, runOutcome(last, checks)),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            nextRunWords(automation, now: now),
            style: small,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

enum _CardAction { runNow, edit, duplicate, runs, delete }

class _CardMenu extends ConsumerWidget {
  const _CardMenu({required this.automation});

  final Automation automation;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      PopupMenuButton<_CardAction>(
        key: ValueKey('automation-menu-${automation.id}'),
        tooltip: 'More for ${automation.name}',
        icon: const Icon(AppIcons.dotsThree),
        onSelected: (action) {
          switch (action) {
            case _CardAction.runNow:
              runAutomationNow(context, ref, automation);
            case _CardAction.edit:
              ref.read(automationEditorProvider.notifier).edit(automation);
            case _CardAction.duplicate:
              // Opened to create, not saved: saving a copy is arming it.
              ref
                  .read(automationEditorProvider.notifier)
                  .open(AutomationDraft.from(automation).asNewCopy());
            case _CardAction.runs:
              showRunsOf(ref, automation.id);
            case _CardAction.delete:
              confirmDeleteAutomation(context, ref, automation);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: _CardAction.runNow, child: Text('Run now')),
          PopupMenuItem(value: _CardAction.edit, child: Text('Edit')),
          PopupMenuItem(value: _CardAction.duplicate, child: Text('Duplicate')),
          PopupMenuItem(value: _CardAction.runs, child: Text('See its runs')),
          PopupMenuItem(value: _CardAction.delete, child: Text('Delete…')),
        ],
      );
}
