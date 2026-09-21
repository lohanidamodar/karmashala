import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/agent_state_providers.dart';
import '../application/agent_states.dart';
import '../application/explorer_view_mode.dart';
import 'lens_session_row.dart';

/// The Explorer's way to the Agents page, and the one place it says how many
/// sessions wait on the user. The count is drawn only above zero: an empty
/// badge is chrome that says nothing.
class AgentsEntryRow extends ConsumerWidget {
  const AgentsEntryRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(needsYouCountProvider);
    final open = ref.watch(
      explorerLensProvider.select((lens) => lens == ExplorerLens.agents),
    );
    final waiting = count == 1
        ? '1 session waiting on you'
        : '$count sessions waiting on you';
    return Semantics(
      button: true,
      selected: open,
      label: count > 0 ? 'Agents, $waiting' : 'Agents',
      excludeSemantics: true,
      onTap: () =>
          ref.read(explorerLensProvider.notifier).toggle(ExplorerLens.agents),
      child: Tooltip(
        message: open ? 'Back to projects' : 'Every session, by what it needs',
        child: ExplorerRow(
          kind: ExplorerRowKind.group,
          depth: 0,
          selected: open,
          onTap: () => ref
              .read(explorerLensProvider.notifier)
              .toggle(ExplorerLens.agents),
          builder: (context) {
            final theme = Theme.of(context);
            final density = UiDensity.of(context);
            return ExplorerRowLine(
              lead: const ExplorerRowLead(
                glyph: Icon(AppIcons.robot, size: ExplorerRow.glyphSize),
              ),
              title: Text(
                'Agents',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: density.rowTitle(theme, strong: count > 0),
              ),
              trailing: count > 0
                  ? ExplorerRowTrailing(meta: NeedsYouPill(count: count))
                  : null,
            );
          },
        ),
      ),
    );
  }
}

/// `2 need you` on the attention tone. Words beside the colour, never the
/// colour alone.
class NeedsYouPill extends StatelessWidget {
  const NeedsYouPill({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final attention = SemanticColors.of(context).attention;
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('agents-needs-you-pill'),
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs + 2),
      decoration: BoxDecoration(
        color: attention.withValues(alpha: StateLayers.selectedAlpha),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: attention,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Every session across projects, grouped by state in [AgentState] order.
/// Needs you, Working and Failed are always whole; Ready shows
/// [kReadyVisibleRows] and folds the rest; Ended starts folded.
class AgentsPage extends ConsumerStatefulWidget {
  const AgentsPage({super.key});

  @override
  ConsumerState<AgentsPage> createState() => _AgentsPageState();
}

class _AgentsPageState extends ConsumerState<AgentsPage> {
  /// The groups the user opened. Ephemeral: the page starts as specified.
  final _opened = <AgentState>{};

  void _toggle(AgentState state) => setState(() {
    if (!_opened.remove(state)) _opened.add(state);
  });

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(agentStateGroupsProvider);
    final items = <Widget>[];
    for (final group in groups) {
      if (group.isEmpty) continue;
      final opened = _opened.contains(group.state);
      final shown = visibleRowCount(group, expanded: opened);
      items.add(
        _StateHeader(
          key: ValueKey('agents-group:${group.state.name}'),
          group: group,
          expanded: switch (group.state.fold) {
            AgentStateFold.open => null,
            AgentStateFold.capped => null,
            AgentStateFold.folded => opened,
          },
          onTap: group.state.fold == AgentStateFold.folded
              ? () => _toggle(group.state)
              : null,
          spaceAbove: items.isNotEmpty,
        ),
      );
      for (final entry in group.entries.take(shown)) {
        items.add(LensSessionRow(key: ValueKey(entry.id), entry: entry));
      }
      if (group.state.fold == AgentStateFold.capped &&
          group.length > kReadyVisibleRows) {
        items.add(
          _FoldRow(
            key: ValueKey('agents-fold:${group.state.name}'),
            label: opened
                ? 'Show fewer'
                : 'Show ${group.length - kReadyVisibleRows} more',
            onTap: () => _toggle(group.state),
          ),
        );
      }
    }
    if (items.isEmpty) {
      return const PanePlaceholder(message: 'No sessions yet.');
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: ExplorerRow.gap),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }
}

class _StateHeader extends StatelessWidget {
  const _StateHeader({
    required this.group,
    required this.expanded,
    required this.onTap,
    required this.spaceAbove,
    super.key,
  });

  final AgentStateGroup group;

  /// Null for a group that does not fold.
  final bool? expanded;
  final VoidCallback? onTap;
  final bool spaceAbove;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.group,
    depth: 0,
    selected: false,
    band: true,
    spaceAbove: spaceAbove,
    expanded: expanded,
    onTap: onTap,
    builder: (context) {
      final theme = Theme.of(context);
      return ExplorerRowLine(
        lead: ExplorerRowLead(expanded: expanded),
        title: Text(
          group.state.label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall
              ?.merge(Chrome.groupLabel)
              .copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: ExplorerRowTrailing(
          meta: ExplorerRowMeta(
            '${group.length}',
            tooltip: group.length == 1
                ? '1 session'
                : '${group.length} sessions',
          ),
        ),
      );
    },
  );
}

class _FoldRow extends StatelessWidget {
  const _FoldRow({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.session,
    depth: 0,
    selected: false,
    onTap: onTap,
    builder: (context) => ExplorerRowLine(
      lead: const ExplorerRowLead(),
      title: Text(label, style: UiDensity.of(context).muted(Theme.of(context))),
    ),
  );
}
