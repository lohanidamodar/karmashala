import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../agents/application/agent_providers.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../../sessions/application/session_list_prefs.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';

/// The filters that narrow mission control right now, as chips say them.
final overviewActiveFiltersProvider =
    Provider.autoDispose<List<OverviewActiveFilter>>((ref) {
      final facts = ref.watch(overviewFactsProvider);
      final registry = ref.watch(agentRegistryProvider);
      return activeFiltersOf(
        ref.watch(overviewPrefsProvider.select((p) => p.filter)),
        projects: facts.projects,
        machines: facts.machines,
        agentName: registry.displayNameFor,
        showArchived: ref.watch(showArchivedSessionsProvider),
      );
    });

/// The agents mission control's sessions run, by id.
final _overviewAgentsProvider = Provider.autoDispose<List<String>>((ref) {
  final facts = ref.watch(overviewFactsProvider);
  return {
    for (final entry in ref.watch(workspaceSessionsProvider))
      ?facts.agentOf(entry),
  }.toList()..sort();
});

/// Clears the filter [kind] names.
void clearOverviewFilter(WidgetRef ref, OverviewFilterKind kind) {
  final prefs = ref.read(overviewPrefsProvider.notifier);
  switch (kind) {
    case OverviewFilterKind.projects:
      prefs.showAllProjects();
    case OverviewFilterKind.agents:
      prefs.setAgents(null);
    case OverviewFilterKind.machines:
      prefs.setMachines(null);
    case OverviewFilterKind.archived:
      ref.read(sessionListPrefsProvider.notifier).setShowArchived(false);
  }
}

Future<void> _showFilters(BuildContext context) => showAdaptiveModal<void>(
  context: context,
  title: 'Filters',
  builder: (_) => const OverviewFilterPanel(),
);

/// **The one filter control**: a funnel with a count of what is set, opening
/// the filters as a sheet on a phone and a dialog elsewhere.
class OverviewFilterButton extends ConsumerWidget {
  const OverviewFilterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilterFunnelButton(
    key: const ValueKey('overview-filter-button'),
    count: ref.watch(overviewActiveFiltersProvider).length,
    onPressed: () => _showFilters(context),
  );
}

/// Group by, projects, agent, machine and archived sessions. Every change
/// is kept at once in this device's prefs.
class OverviewFilterPanel extends ConsumerWidget {
  const OverviewFilterPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(overviewPrefsProvider);
    final controller = ref.read(overviewPrefsProvider.notifier);
    final facts = ref.watch(overviewFactsProvider);
    final filter = prefs.filter;
    final registry = ref.watch(agentRegistryProvider);
    final agents = ref.watch(_overviewAgentsProvider);
    final showArchived = ref.watch(showArchivedSessionsProvider);
    final active = ref.watch(overviewActiveFiltersProvider);

    Widget section(String label, Widget child) => Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EyebrowLabel(label),
          const SizedBox(height: Insets.sm),
          child,
        ],
      ),
    );
    Widget chips(List<(String, String, bool, VoidCallback)> choices) => Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.sm,
      children: [
        for (final (key, label, on, tap) in choices)
          FilterChip(
            key: ValueKey(key),
            label: Text(label),
            selected: on,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => tap(),
          ),
      ],
    );

    // A dialog does not scroll its content; a long project list must.
    return SingleChildScrollView(
      key: const ValueKey('overview-filter-panel'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section(
            'Group by',
            Align(
              alignment: Alignment.centerLeft,
              child: CompactSegmented<OverviewGroupBy>(
                key: const ValueKey('overview-filter-group'),
                segments: [
                  for (final by in OverviewGroupBy.values)
                    if (by != OverviewGroupBy.context ||
                        facts.contexts.isNotEmpty)
                      ButtonSegment(
                        value: by,
                        label: Text(
                          by.label,
                          key: ValueKey('group-by:${by.name}'),
                        ),
                      ),
                ],
                selected: ref.watch(overviewGroupByProvider),
                onChanged: controller.setGroupBy,
              ),
            ),
          ),
          section(
            'Sub-sessions',
            Align(
              alignment: Alignment.centerLeft,
              child: CompactSegmented<OverviewSubSessionMode>(
                key: const ValueKey('overview-filter-subs'),
                segments: [
                  for (final mode in OverviewSubSessionMode.values)
                    ButtonSegment(
                      value: mode,
                      label: Text(
                        mode.label,
                        key: ValueKey('sub-sessions:${mode.name}'),
                      ),
                    ),
                ],
                selected: ref.watch(overviewSubSessionsProvider),
                onChanged: controller.setSubSessions,
              ),
            ),
          ),
          if (facts.projects.isNotEmpty)
            section(
              'Projects',
              chips([
                for (final project in facts.projects)
                  (
                    'overview-filter-project:${project.id}',
                    project.label,
                    filter.projects?.contains(project.id) ?? true,
                    () => controller.toggleProject(
                      project.id,
                      all: [for (final p in facts.projects) p.id],
                    ),
                  ),
              ]),
            ),
          if (agents.length > 1)
            section(
              'Agent',
              chips([
                for (final agent in agents)
                  (
                    'overview-filter-agent:$agent',
                    registry.displayNameFor(agent),
                    filter.agents?.contains(agent) ?? true,
                    () => controller.setAgents(
                      toggledIn(filter.agents, agent, agents),
                    ),
                  ),
              ]),
            ),
          if (facts.machines.length > 1)
            section(
              'Machine',
              chips([
                for (final machine in facts.machines)
                  (
                    'overview-filter-machine:${machine.id}',
                    machine.label,
                    filter.machines?.contains(machine.id) ?? true,
                    () => controller.setMachines(
                      toggledIn(filter.machines, machine.id, [
                        for (final m in facts.machines) m.id,
                      ]),
                    ),
                  ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.only(top: Insets.sm),
            child: SwitchListTile(
              key: const ValueKey('overview-filter-archived'),
              title: const Text('Show archived sessions'),
              value: showArchived,
              onChanged: ref
                  .read(sessionListPrefsProvider.notifier)
                  .setShowArchived,
            ),
          ),
          if (active.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('overview-filter-clear'),
                  onPressed: () {
                    for (final chip in active) {
                      clearOverviewFilter(ref, chip.kind);
                    }
                  },
                  child: const Text('Clear filters'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The filters set, as chips that clear them; nothing when none is set.
class OverviewActiveFilterChips extends ConsumerWidget {
  const OverviewActiveFilterChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(overviewActiveFiltersProvider);
    if (active.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: const ValueKey('overview-active-filters'),
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      children: [
        for (final chip in active)
          FilterChip(
            key: ValueKey('overview-active-filter:${chip.kind.name}'),
            label: Text(chip.label),
            selected: true,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _showFilters(context),
            onDeleted: () => clearOverviewFilter(ref, chip.kind),
            deleteButtonTooltipMessage: 'Clear ${chip.label}',
          ),
      ],
    );
  }
}
