import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_providers.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../../sessions/application/session_list_prefs.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';

/// Rows by, projects (several at once), agent, machine and state, the density
/// and Show archived. Filters only narrow the picture; there is no search —
/// the sidebars list and search.
class OverviewFilterBar extends ConsumerWidget {
  const OverviewFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(overviewPrefsProvider);
    final controller = ref.read(overviewPrefsProvider.notifier);
    final facts = ref.watch(overviewFactsProvider);
    final filter = prefs.filter;
    final registry = ref.watch(agentRegistryProvider);
    final agents = {
      for (final entry in ref.watch(workspaceSessionsProvider))
        ?facts.agentOf(entry),
    }.toList()..sort();
    final showArchived = ref.watch(showArchivedSessionsProvider);

    String summary(Set<Object>? shown, int all, String noun) =>
        shown == null ? 'All $noun' : '${shown.length} of $all';

    return Wrap(
      key: const ValueKey('overview-filters'),
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Menu<OverviewGroupBy>(
          label: 'Group by: ${prefs.groupBy.label}',
          items: [
            for (final by in OverviewGroupBy.values)
              (by, by.label, prefs.groupBy == by),
          ],
          onPicked: controller.setGroupBy,
        ),
        _Menu<String>(
          key: const ValueKey('overview-filter-projects'),
          label:
              'Projects: '
              '${summary(filter.projects, facts.projects.length, 'projects')}',
          items: [
            for (final project in facts.projects)
              (
                project.id,
                project.label,
                filter.projects?.contains(project.id) ?? true,
              ),
          ],
          onPicked: (id) => controller.toggleProject(
            id,
            all: [for (final p in facts.projects) p.id],
          ),
        ),
        if (agents.length > 1)
          _Menu<String>(
            label: 'Agent: ${summary(filter.agents, agents.length, 'agents')}',
            items: [
              for (final agent in agents)
                (
                  agent,
                  registry.displayNameFor(agent),
                  filter.agents?.contains(agent) ?? true,
                ),
            ],
            onPicked: (agent) =>
                controller.setAgents(toggledIn(filter.agents, agent, agents)),
          ),
        if (facts.machines.length > 1)
          _Menu<String>(
            label:
                'Machine: '
                '${summary(filter.machines, facts.machines.length, 'machines')}',
            items: [
              for (final machine in facts.machines)
                (
                  machine.id,
                  machine.label,
                  filter.machines?.contains(machine.id) ?? true,
                ),
            ],
            onPicked: (id) => controller.setMachines(
              toggledIn(filter.machines, id, [
                for (final m in facts.machines) m.id,
              ]),
            ),
          ),
        _Menu<BoardColumn>(
          label:
              'State: '
              '${summary(filter.columns, BoardColumn.values.length, 'states')}',
          items: [
            for (final column in BoardColumn.values)
              (column, column.label, filter.columns?.contains(column) ?? true),
          ],
          onPicked: (column) => controller.setColumns(
            toggledIn(filter.columns, column, BoardColumn.values),
          ),
        ),
        FilterChip(
          label: const Text('Show archived'),
          selected: showArchived,
          visualDensity: VisualDensity.compact,
          onSelected: ref
              .read(sessionListPrefsProvider.notifier)
              .setShowArchived,
        ),
        IconButton(
          key: const ValueKey('overview-density'),
          tooltip: prefs.density == OverviewDensity.cards
              ? 'One line per session'
              : 'Cards',
          icon: Icon(
            prefs.density == OverviewDensity.cards
                ? AppIcons.list
                : AppIcons.squaresFour,
          ),
          onPressed: () => controller.setDensity(
            prefs.density == OverviewDensity.cards
                ? OverviewDensity.lines
                : OverviewDensity.cards,
          ),
        ),
      ],
    );
  }
}

/// A button that opens a menu of ticked choices.
class _Menu<T> extends StatelessWidget {
  const _Menu({
    required this.label,
    required this.items,
    required this.onPicked,
    super.key,
  });

  final String label;

  /// Value, label, ticked.
  final List<(T, String, bool)> items;
  final ValueChanged<T> onPicked;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: label,
    onSelected: onPicked,
    itemBuilder: (context) => [
      for (final (value, text, ticked) in items)
        CheckedPopupMenuItem<T>(
          value: value,
          checked: ticked,
          child: Text(text),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const Icon(AppIcons.caretDown, size: 12),
        ],
      ),
    ),
  );
}
