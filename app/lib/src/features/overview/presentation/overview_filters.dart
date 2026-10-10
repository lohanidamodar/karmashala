import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/util.dart' show matchesSearch;
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

/// Clears every filter the panel sets.
void resetOverviewFilters(WidgetRef ref) {
  for (final chip in ref.read(overviewActiveFiltersProvider)) {
    clearOverviewFilter(ref, chip.kind);
  }
}

/// The panel's title, where a sheet or a screen reader names it.
const String kOverviewFilterTitle = 'View and filters';

/// From this many choices a checklist gets a search box.
const int kOverviewChecklistSearchFrom = 6;

Future<void> _showFilters(BuildContext context) => showAdaptivePopover<void>(
  context: context,
  title: kOverviewFilterTitle,
  builder: (_) => const OverviewFilterPanel(),
);

/// **The one filter control**: a funnel with a count of what is set, opening
/// the view and filters as a sheet on a phone and a popover under it
/// elsewhere.
class OverviewFilterButton extends ConsumerWidget {
  const OverviewFilterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilterFunnelButton(
    key: const ValueKey('overview-filter-button'),
    count: ref.watch(overviewActiveFiltersProvider).length,
    onPressed: () => _showFilters(context),
  );
}

/// **View** — group by, sub-sessions, what a card shows — and **Filter** —
/// projects, agents, machines and archived sessions. Every change applies and
/// is kept at once in this device's prefs.
class OverviewFilterPanel extends ConsumerWidget {
  const OverviewFilterPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final prefs = ref.watch(overviewPrefsProvider);
    final controller = ref.read(overviewPrefsProvider.notifier);
    final facts = ref.watch(overviewFactsProvider);
    final filter = prefs.filter;
    final registry = ref.watch(agentRegistryProvider);
    final agents = ref.watch(_overviewAgentsProvider);
    final counts = ref.watch(overviewFilterCountsProvider);
    final showArchived = ref.watch(showArchivedSessionsProvider);
    final active = ref.watch(overviewActiveFiltersProvider);
    final details = ref.watch(overviewCardDetailsProvider);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    const side = EdgeInsets.symmetric(horizontal: Insets.lg);
    Widget field(String label, Widget control) => Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: Insets.xs),
          Align(alignment: AlignmentDirectional.centerStart, child: control),
        ],
      ),
    );

    // Context is offered only where a context exists to show.
    final toggles = [
      for (final detail in OverviewCardDetail.values)
        if (detail != OverviewCardDetail.context || facts.contexts.isNotEmpty)
          detail,
    ];
    final same = [
      for (final detail in toggles)
        if (details.same.contains(detail)) detail.label,
    ];

    List<OverviewChecklistOption> optionsOf(
      List<OverviewLaneKey> keys,
      Map<String?, int> count,
      Set<String>? kept,
    ) => [
      for (final key in keys)
        if ((count[key.id] ?? 0) > 0 || (kept?.contains(key.id) ?? false))
          (id: key.id, label: key.label, count: count[key.id] ?? 0),
    ];

    return SingleChildScrollView(
      key: const ValueKey('overview-filter-panel'),
      padding: const EdgeInsets.only(top: Insets.sm, bottom: Insets.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const EyebrowLabel('View', padding: side),
          field(
            'Group by',
            CompactSegmented<OverviewGroupBy>(
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
          field(
            'Sub-sessions',
            CompactSegmented<OverviewSubSessionMode>(
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
          field(
            'Show on cards',
            Wrap(
              key: const ValueKey('overview-show-on-cards'),
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              children: [
                for (final detail in toggles)
                  FilterChip(
                    key: ValueKey('overview-show:${detail.name}'),
                    label: Text(detail.label),
                    selected: !prefs.hiddenDetails.contains(detail),
                    visualDensity: UiDensity.of(context).controlDensity,
                    onSelected: (on) => controller.setDetailShown(detail, on),
                  ),
              ],
            ),
          ),
          if (same.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.xs,
                Insets.lg,
                0,
              ),
              child: Text(
                '${same.join(' and ')} ${same.length == 1 ? 'is' : 'are'} '
                'the same on every card in view, so left off for now.',
                key: const ValueKey('overview-show-same'),
                style: muted,
              ),
            ),
          const Divider(height: Insets.xl),
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: Insets.lg,
              end: Insets.sm,
            ),
            child: Row(
              children: [
                const Expanded(child: EyebrowLabel('Filter')),
                TextButton(
                  key: const ValueKey('overview-filter-reset'),
                  onPressed: active.isEmpty
                      ? null
                      : () => resetOverviewFilters(ref),
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
          OverviewChecklist(
            keyPrefix: 'overview-filter-project',
            title: 'Projects',
            noun: 'projects',
            options: optionsOf(
              facts.projects,
              counts.projects,
              filter.projects,
            ),
            selected: filter.projects,
            onChanged: (projects) => projects == null
                ? controller.showAllProjects()
                : controller.setProjects(projects),
          ),
          OverviewChecklist(
            keyPrefix: 'overview-filter-agent',
            title: 'Agent',
            noun: 'agents',
            options: [
              for (final agent in agents)
                if ((counts.agents[agent] ?? 0) > 0 ||
                    (filter.agents?.contains(agent) ?? false))
                  (
                    id: agent,
                    label: registry.displayNameFor(agent),
                    count: counts.agents[agent] ?? 0,
                  ),
            ],
            selected: filter.agents,
            onChanged: controller.setAgents,
          ),
          OverviewChecklist(
            keyPrefix: 'overview-filter-machine',
            title: 'Machine',
            noun: 'machines',
            options: optionsOf(
              facts.machines,
              counts.machines,
              filter.machines,
            ),
            selected: filter.machines,
            onChanged: controller.setMachines,
          ),
          SwitchListTile(
            key: const ValueKey('overview-filter-archived'),
            dense: true,
            contentPadding: side,
            title: const Text('Show archived sessions'),
            value: showArchived,
            onChanged: ref
                .read(sessionListPrefsProvider.notifier)
                .setShowArchived,
          ),
        ],
      ),
    );
  }
}

/// One choice of an [OverviewChecklist]: its id, its name, and how many
/// sessions it holds.
typedef OverviewChecklistOption = ({String id, String label, int count});

/// "Showing 2 of 5 projects", or every one of them.
String overviewChecklistSummary(
  Set<String>? selected,
  List<String> ids,
  String noun,
) {
  if (selected == null) return 'Showing all ${ids.length} $noun';
  final shown = ids.where(selected.contains).length;
  return 'Showing $shown of ${ids.length} $noun';
}

/// A filter as a checklist: a tick per choice with its count, **Only** to
/// keep that one, **All** to clear it, and a search box once the list is
/// long. [selected] null is every choice, so one added later shows too. With
/// a single choice and nothing set, there is nothing to pick and it is not
/// drawn.
class OverviewChecklist extends StatefulWidget {
  const OverviewChecklist({
    required this.keyPrefix,
    required this.title,
    required this.noun,
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// Each row is keyed `<keyPrefix>:<id>`, its Only `<keyPrefix>-only:<id>`.
  final String keyPrefix;
  final String title;

  /// The plural the summary counts in.
  final String noun;
  final List<OverviewChecklistOption> options;
  final Set<String>? selected;
  final ValueChanged<Set<String>?> onChanged;

  @override
  State<OverviewChecklist> createState() => _OverviewChecklistState();
}

class _OverviewChecklistState extends State<OverviewChecklist> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<String> get _ids => [for (final option in widget.options) option.id];

  void _toggle(String id) =>
      widget.onChanged(toggledIn(widget.selected, id, _ids));

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    final selected = widget.selected;
    if (options.length <= 1 && selected == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final query = _query.text.trim();
    final shown = [
      for (final option in options)
        if (query.isEmpty || matchesSearch(query, option.label)) option,
    ];

    return Padding(
      key: ValueKey('${widget.keyPrefix}s'),
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: Insets.lg,
              end: Insets.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: widget.title),
                        TextSpan(
                          text:
                              '  ${overviewChecklistSummary(selected, _ids, widget.noun)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    key: ValueKey('${widget.keyPrefix}-summary'),
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                TextButton(
                  key: ValueKey('${widget.keyPrefix}-all'),
                  onPressed: selected == null
                      ? null
                      : () => widget.onChanged(null),
                  child: const Text('All'),
                ),
              ],
            ),
          ),
          if (options.length >= kOverviewChecklistSearchFrom)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                0,
                Insets.lg,
                Insets.xs,
              ),
              child: SearchField(
                key: ValueKey('${widget.keyPrefix}-search'),
                controller: _query,
                style: theme.textTheme.bodyMedium,
                decoration: compactSearchDecoration(
                  hintText: 'Search ${widget.noun}',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          for (final option in shown)
            _ChecklistRow(
              key: ValueKey('${widget.keyPrefix}:${option.id}'),
              onlyKey: ValueKey('${widget.keyPrefix}-only:${option.id}'),
              option: option,
              on: selected?.contains(option.id) ?? true,
              onToggle: () => _toggle(option.id),
              onOnly: () => widget.onChanged({option.id}),
            ),
          if (shown.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: Insets.lg,
                vertical: density.isTouch ? Insets.md : Insets.sm,
              ),
              child: Text(
                'No ${widget.noun} match “${_query.text.trim()}”',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// A tick, the name, its count and **Only**.
class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.onlyKey,
    required this.option,
    required this.on,
    required this.onToggle,
    required this.onOnly,
    super.key,
  });

  final Key onlyKey;
  final OverviewChecklistOption option;
  final bool on;
  final VoidCallback onToggle;
  final VoidCallback onOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onToggle,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: density.minRow),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: Insets.sm,
            end: Insets.sm,
          ),
          child: Row(
            children: [
              Checkbox(
                value: on,
                visualDensity: density.controlDensity,
                materialTapTargetSize: density.tapTargetSize,
                onChanged: (_) => onToggle(),
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: on ? null : muted,
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              Text(
                '${option.count}',
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
              TextButton(
                key: onlyKey,
                style: TextButton.styleFrom(
                  visualDensity: density.controlDensity,
                  tapTargetSize: density.tapTargetSize,
                  foregroundColor: muted,
                ),
                onPressed: onOnly,
                child: const Text('Only'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The filters set, as chips that clear them, on one line: what does not fit
/// folds into a "+N" chip that opens the panel. Nothing when none is set.
class OverviewActiveFilterChips extends ConsumerWidget {
  const OverviewActiveFilterChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(overviewActiveFiltersProvider);
    if (active.isEmpty) return const SizedBox.shrink();
    return _FoldRow(
      key: const ValueKey('overview-active-filters'),
      chips: [
        for (final chip in active)
          FilterChip(
            key: ValueKey('overview-active-filter:${chip.kind.name}'),
            label: Text(
              chip.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: true,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _showFilters(context),
            onDeleted: () => clearOverviewFilter(ref, chip.kind),
            deleteButtonTooltipMessage: 'Clear ${chip.label}',
          ),
      ],
      folds: [
        for (var n = 1; n <= active.length; n++)
          Tooltip(
            message: [
              for (final chip in active.skip(active.length - n)) chip.label,
            ].join('\n'),
            child: ActionChip(
              key: ValueKey('overview-active-filter-fold:$n'),
              label: Text('+$n'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showFilters(context),
            ),
          ),
      ],
    );
  }
}

/// [chips] in a row, as many as fit; the rest are counted by `folds[n - 1]`,
/// the "+n" chip.
class _FoldRow extends MultiChildRenderObjectWidget {
  _FoldRow({
    required List<Widget> chips,
    required List<Widget> folds,
    super.key,
  }) : assert(chips.length == folds.length),
       count = chips.length,
       super(children: [...chips, ...folds]);

  final int count;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFoldRow(count);

  @override
  void updateRenderObject(BuildContext context, _RenderFoldRow renderObject) =>
      renderObject.count = count;
}

class _FoldParentData extends ContainerBoxParentData<RenderBox> {
  bool shown = false;
}

class _RenderFoldRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FoldParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FoldParentData> {
  _RenderFoldRow(this._count);

  int _count;
  set count(int value) {
    if (value == _count) return;
    _count = value;
    markNeedsLayout();
  }

  static const _gap = Insets.sm;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FoldParentData) {
      child.parentData = _FoldParentData();
    }
  }

  @override
  void performLayout() {
    final all = getChildrenAsList();
    final chips = all.take(_count).toList();
    final folds = all.skip(_count).toList();
    final loose = BoxConstraints(maxWidth: constraints.maxWidth);
    for (final child in all) {
      child.layout(loose, parentUsesSize: true);
      (child.parentData! as _FoldParentData).shown = false;
    }
    double widthOf(int kept) {
      var width = 0.0;
      for (var i = 0; i < kept; i++) {
        width += chips[i].size.width + (i > 0 ? _gap : 0);
      }
      if (kept < _count) {
        width += folds[_count - kept - 1].size.width + (kept > 0 ? _gap : 0);
      }
      return width;
    }

    var kept = _count;
    while (kept > 1 && widthOf(kept) > constraints.maxWidth) {
      kept--;
    }
    // The first chip is always drawn, its label shortened to leave the fold
    // its room.
    if (kept == 1 && widthOf(1) > constraints.maxWidth) {
      final fold = _count > 1 ? folds[_count - 2].size.width + _gap : 0.0;
      chips.first.layout(
        BoxConstraints(maxWidth: math.max(0, constraints.maxWidth - fold)),
        parentUsesSize: true,
      );
    }
    final shown = [
      ...chips.take(kept),
      if (kept < _count) folds[_count - kept - 1],
    ];
    final height = shown.fold(0.0, (h, c) => math.max(h, c.size.height));
    var x = 0.0;
    for (final child in shown) {
      final data = child.parentData! as _FoldParentData;
      data
        ..shown = true
        ..offset = Offset(x, (height - child.size.height) / 2);
      x += child.size.width + _gap;
    }
    size = constraints.constrain(Size(math.max(0, x - _gap), height));
  }

  Iterable<RenderBox> get _shown sync* {
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _FoldParentData;
      if (data.shown) yield child;
      child = data.nextSibling;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _shown) {
      context.paintChild(
        child,
        (child.parentData! as _FoldParentData).offset + offset,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _shown.toList().reversed) {
      final offset = (child.parentData! as _FoldParentData).offset;
      final hit = result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) =>
      _shown.forEach(visitor);
}
