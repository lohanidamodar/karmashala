import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/shell_state.dart';
import '../../projects/application/projects_controller.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_provider.dart';
import '../application/explorer_tree_state.dart';
import '../application/explorer_view_mode.dart';
import '../application/session_selection.dart';
import 'explorer_header_actions.dart';
import 'explorer_sections_view.dart';
import 'explorer_tree_rows.dart';
import 'session_selection_bar.dart';

/// The unified left pane: Project → Session, and deliberately nothing else;
/// checkout rows were removed for their git cost (`checkout_scale_cost_test`).
///
/// It watches only the tree's shape and its own chrome. Every reading a row
/// draws is watched by that row, so a session's tick rebuilds one row.
class ExplorerPanel extends ConsumerWidget {
  const ExplorerPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused = ref.watch(
      shellControllerProvider.select(
        (s) => s.focusedPane == ShellPane.explorer,
      ),
    );
    final hasProjects = ref.watch(
      sortedProjectsProvider.select((p) => p.isNotEmpty),
    );
    // Only whether the mode is on, never the ticked set.
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final showingViews = ref.watch(explorerShowingViewsProvider);

    return PaneScaffold(
      title: 'Explorer',
      // No glyph: the title-bar toggle draws this pane's mark 30px above, in
      // the same column — see [PaneHeader.icon].
      focused: focused,
      actions: const [ExplorerHeaderActions()],
      body: Column(
        children: [
          if (hasProjects)
            ExplorerSearchField(
              onChanged: (query) =>
                  ref.read(explorerSearchQueryProvider.notifier).set(query),
            ),
          if (selecting) const SessionSelectionBar(),
          Expanded(
            child: showingViews
                ? const ExplorerSectionsList()
                : hasProjects
                ? const ExplorerTreeView()
                : const PanePlaceholder(
                    message:
                        'No projects yet.\nUse + to create one from a folder, '
                        'then its CLI sessions are imported automatically.',
                  ),
          ),
        ],
      ),
    );
  }
}

/// The search box above the tree.
class ExplorerSearchField extends StatelessWidget {
  const ExplorerSearchField({required this.onChanged, super.key});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    // Inset to the row tiles' own edges: the field and the rows beneath it
    // are one column, not two things that nearly line up.
    padding: const EdgeInsets.fromLTRB(
      Insets.xs,
      Insets.sm,
      Insets.xs,
      Insets.xs,
    ),
    child: TextField(
      decoration: const InputDecoration(
        isDense: true,
        prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
        hintText: 'Search projects',
        border: OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );
}

/// The saved sections, in place of the tree.
class ExplorerSectionsList extends ConsumerWidget {
  const ExplorerSectionsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.symmetric(vertical: ExplorerRow.gap),
    children: explorerSectionNodes(ref),
  );
}

/// The Machine → Project → Session tree, built lazily.
class ExplorerTreeView extends ConsumerStatefulWidget {
  const ExplorerTreeView({super.key});

  @override
  ConsumerState<ExplorerTreeView> createState() => _ExplorerTreeViewState();
}

class _ExplorerTreeViewState extends ConsumerState<ExplorerTreeView> {
  final _scroll = ScrollController();

  /// The row the selection was last scrolled to. A reveal happens on a
  /// *change* of selection, never on every build, or the list would fight the
  /// user's own scrolling.
  String? _revealed;

  /// Held by the selected project's row while it is on screen, so the reveal
  /// can finish exactly rather than at its estimate.
  final _selectedRow = GlobalKey();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the selected project into view. The list is built lazily, so an
  /// off-screen row has no context to scroll to: jump by the proportion of the
  /// list it sits at, then settle exactly once it exists.
  void _revealSelected(int index, int total) {
    if (!mounted || !_scroll.hasClients || total == 0) return;
    void settle() {
      final target = _selectedRow.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.3,
        duration: const Duration(milliseconds: 120),
      );
    }

    if (_selectedRow.currentContext != null) {
      settle();
      return;
    }
    final position = _scroll.position;
    final content = position.maxScrollExtent + position.viewportDimension;
    final guess = content * index / total - position.viewportDimension / 3;
    _scroll.jumpTo(guess.clamp(0.0, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) settle();
    });
  }

  @override
  Widget build(BuildContext context) {
    final nodes = ref.watch(explorerTreeProvider).nodes;
    // A selection that moved — by a click, or by the pane on screen going
    // somewhere — is brought into view once, after this frame.
    final selectedProjectId = ref.watch(selectedProjectIdProvider);
    if (selectedProjectId != _revealed) {
      final index = nodes.indexWhere(
        (node) => node is ProjectNode && node.project.id == selectedProjectId,
      );
      _revealed = selectedProjectId;
      if (index >= 0) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _revealSelected(index, nodes.length),
        );
      }
    }
    if (nodes.isEmpty) {
      return PanePlaceholder(
        message:
            'No projects match "${ref.watch(explorerSearchQueryProvider)}".',
      );
    }
    return ListView.builder(
      // Only the rows on screen are inflated, so the tree costs what is
      // visible rather than what the workspace holds.
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: ExplorerRow.gap),
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        return ExplorerTreeRow(
          key: ValueKey(node.id),
          node: node,
          anchorKey: node is ProjectNode && node.project.id == selectedProjectId
              ? _selectedRow
              : null,
        );
      },
    );
  }
}
