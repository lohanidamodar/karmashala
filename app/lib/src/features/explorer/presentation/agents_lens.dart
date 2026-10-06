import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../application/agent_state_providers.dart';
import '../application/agent_states.dart';
import '../application/explorer_view_mode.dart';
import '../application/session_list_snapshot.dart';
import '../application/session_selection.dart';
import 'archived_sessions_row.dart';
import 'explorer_selection_actions.dart';
import 'lens_session_row.dart';
import 'purge_progress_strip.dart';
import 'session_selection_bar.dart';
import 'sidebar_chrome.dart';
import 'stale_session_list.dart';

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
        // The one amber rest every needs-you fill draws.
        color: SurfaceTones.of(context).attentionSurface,
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
  /// An extended FAB (56) and its 16 margin, with a gap above it.
  static const _fabClearance = 88.0;

  /// The groups the user opened. Ephemeral: the page starts as specified.
  final _opened = <AgentState>{};

  void _toggle(AgentState state) => setState(() {
    if (!_opened.remove(state)) _opened.add(state);
  });

  /// A remote server's list is saved as it is drawn, and until the server
  /// answers, the last one saved is drawn stale in its place (decision 9).
  @override
  Widget build(BuildContext context) {
    final page = _page(context);
    // The phone draws no sidebar header, so New session is the tab's own
    // (owner); a FAB leaves the rows' ⋮ clear.
    if (!PhoneTabsScope.contains(context)) return page;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: page,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => NewSessionDialog.show(context),
        icon: const Icon(AppIcons.plus),
        label: const Text('New session'),
      ),
    );
  }

  Widget _page(BuildContext context) {
    if (ref.watch(sessionListSnapshotStoreProvider) == null) {
      return _live(context);
    }
    ref.watch(sessionListSnapshotWriterProvider);
    final stale = ref.watch(staleSessionListProvider);
    return AnimatedSwitcher(
      duration: Motion.of(context).base,
      child: stale != null
          ? StaleSessionList(
              key: const ValueKey('agents-stale'),
              snapshot: stale,
            )
          : KeyedSubtree(
              key: const ValueKey('agents-live'),
              child: _live(context),
            ),
    );
  }

  Widget _live(BuildContext context) {
    final groups = ref.watch(agentStateGroupsProvider);
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final shownIds = <String>[];
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
        shownIds.add(entry.id);
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
    final archived = ref.watch(archivedSessionCountProvider);
    if (archived > 0) {
      items.add(
        ArchivedSessionsRow(
          key: const ValueKey('agents-archived'),
          count: archived,
        ),
      );
    }
    if (items.isEmpty) {
      return const PanePlaceholder(message: 'No sessions yet.');
    }
    // Shift-click and Select all range over the rows this page draws, in the
    // order it draws them — not over the project tree's.
    List<String> order(SelectionKind kind) =>
        kind == SelectionKind.sessions ? shownIds : const [];
    return SelectionOrderScope(
      order: order,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => _selectionKeys(event, order),
        child: Column(
          children: [
            if (selecting) const SessionSelectionBar(),
            const PurgeProgressStrip(),
            Expanded(
              child: ListView.builder(
                // Room under the last row for the phone's FAB.
                padding: PhoneTabsScope.contains(context)
                    ? Sidebar.listPadding.copyWith(
                        bottom: Sidebar.listPadding.bottom + _fabClearance,
                      )
                    : Sidebar.listPadding,
                itemCount: items.length,
                itemBuilder: (context, index) => items[index],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Escape leaves selection mode; Ctrl+A ticks every row drawn.
  KeyEventResult _selectionKeys(KeyEvent event, SelectionOrder order) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        ref.read(sessionSelectionProvider).active) {
      ref.read(sessionSelectionProvider.notifier).leave();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyA &&
        (keys.isMetaPressed || keys.isControlPressed) &&
        selectAllVisible(ref, SelectionKind.sessions, order)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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

  /// The label's ink: a group whose name is its state says it in that state's
  /// colour — amber *Needs you*, the accent *Working*, red *Failed* — and the
  /// rest are dim (board A2). The words carry the state; the colour repeats it.
  Color? _ink(BuildContext context) {
    final semantic = SemanticColors.of(context);
    return switch (group.state) {
      AgentState.needsYou => semantic.attention,
      AgentState.working => Theme.of(context).colorScheme.primary,
      AgentState.failed => semantic.failure,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) => SidebarGroupLabel(
    label: group.state.label,
    color: _ink(context),
    count: '${group.length}',
    countTooltip: group.length == 1 ? '1 session' : '${group.length} sessions',
    expanded: expanded,
    onTap: onTap,
    spaceAbove: spaceAbove,
  );
}

class _FoldRow extends StatelessWidget {
  const _FoldRow({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.session,
    minHeight: Sidebar.rowHeight,
    depth: 0,
    selected: false,
    onTap: onTap,
    builder: (context) => ExplorerRowLine(
      lead: const ExplorerRowLead(),
      title: Text(label, style: UiDensity.of(context).muted(Theme.of(context))),
    ),
  );
}
