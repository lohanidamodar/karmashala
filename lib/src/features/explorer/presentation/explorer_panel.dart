import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'explorer_scope_bar.dart';
import 'explorer_selection_actions.dart';
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
    final search = ExplorerSearchField(
      onChanged: (query) =>
          ref.read(explorerSearchQueryProvider.notifier).set(query),
    );

    return PaneScaffold(
      title: 'Explorer',
      // No glyph: the title-bar toggle draws this pane's mark 30px above, in
      // the same column — see [PaneHeader.icon].
      focused: focused,
      actions: const [ExplorerHeaderActions()],
      body: Column(
        children: [
          // The scope — which machine, which context — narrows the tree and
          // not the saved views, which cross both; it is not drawn over them.
          if (hasProjects && showingViews)
            search
          else if (hasProjects) ...[
            ExplorerScopeBar(search: search),
            const ExplorerContextChips(),
          ],
          // Not a stop of its own: it hears keys from the rows and the strip,
          // and never from the search field above it.
          Expanded(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, event) => _selectionKeys(ref, event),
              child: Column(
                children: [
                  if (selecting) const SessionSelectionBar(),
                  Expanded(
                    child: showingViews
                        ? const ExplorerSectionsList()
                        : hasProjects
                        ? const ExplorerTreeView()
                        : const PanePlaceholder(
                            message:
                                'No projects yet.\nUse + to create one from a '
                                'folder, then its CLI sessions are imported '
                                'automatically.',
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Escape leaves selection mode; Cmd or Ctrl+A selects every visible row of the
/// focused row's kind. Space ticks a focused row through the row's own tap.
KeyEventResult _selectionKeys(WidgetRef ref, KeyEvent event) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final keys = HardwareKeyboard.instance;
  if (event.logicalKey == LogicalKeyboardKey.escape &&
      ref.read(sessionSelectionProvider).active) {
    ref.read(sessionSelectionProvider.notifier).leave();
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.keyA &&
      (keys.isMetaPressed || keys.isControlPressed) &&
      selectAllVisible(ref)) {
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
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

/// Context headers over Project → Session, built lazily.
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

  /// Names the list. A new name is a new list, at the top.
  int _generation = 0;

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
        duration: Motion.of(context).fast,
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
    // A search starts at its first match — by a *new* list, not a jump. Rows
    // have no fixed extent, so a list crosses a distance by building every row
    // in it: a jump to the top from row 300 built 300 rows, and a tree that
    // shrank under an offset past its new end built every match to find it.
    ref.listen(explorerSearchQueryProvider, (_, _) {
      if (_scroll.hasClients && _scroll.offset != 0) {
        setState(() => _generation++);
      }
    });
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
    // One lazy list, headers and all: the tree costs what is on screen, not
    // what the workspace holds.
    final list = ListView.builder(
      key: ValueKey(_generation),
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
    // The scrollbar is drawn here rather than by the list, so that it stays
    // over the pinned header instead of passing under it.
    return Scrollbar(
      controller: _scroll,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: list,
          ),
          ExplorerPinnedHeader(
            // A new list starts at the top, with nothing pinned.
            key: ValueKey(_generation),
            controller: _scroll,
            nodes: nodes,
            topPadding: ExplorerRow.gap,
          ),
        ],
      ),
    );
  }
}

/// The group header the list has scrolled past, drawn over its top edge until
/// the next header pushes it out. Not a pinned sliver: a `SliverList` per group
/// inflates a row per group off screen, and this builds none (SETTLED, "The
/// Explorer is two levels").
class ExplorerPinnedHeader extends StatefulWidget {
  const ExplorerPinnedHeader({
    required this.controller,
    required this.nodes,
    required this.topPadding,
    super.key,
  });

  final ScrollController controller;
  final List<ExplorerNode> nodes;

  /// The list's own padding above its first row.
  final double topPadding;

  @override
  State<ExplorerPinnedHeader> createState() => _ExplorerPinnedHeaderState();
}

class _ExplorerPinnedHeaderState extends State<ExplorerPinnedHeader> {
  final _box = GlobalKey();

  /// Index of the pinned header in [ExplorerPinnedHeader.nodes], or null.
  int? _pinned;

  /// How far the next header has pushed this one up; zero or negative.
  double _shift = 0;

  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    FocusManager.instance.addListener(_onFocus);
    _measureAfterLayout();
  }

  @override
  void didUpdateWidget(ExplorerPinnedHeader old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
    if (!identical(old.nodes, widget.nodes)) {
      // The rows have not been laid out against the new tree yet.
      final pinned = _pinned;
      if (pinned != null &&
          (pinned >= widget.nodes.length ||
              widget.nodes[pinned] is! ExplorerHeaderNode)) {
        _pinned = null;
      }
      _measureAfterLayout();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    FocusManager.instance.removeListener(_onFocus);
    super.dispose();
  }

  /// A row the keyboard reaches is brought to the list's top edge — see
  /// `RevealOnFocus` — and the top edge is under this header. Moved clear.
  void _onFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.controller.hasClients) return;
      final focused = FocusManager.instance.primaryFocus?.context;
      final header = _box.currentContext?.findRenderObject();
      if (focused == null || !focused.mounted || header is! RenderBox) return;
      final position = widget.controller.position;
      if (Scrollable.maybeOf(focused)?.position != position) return;
      final row = focused.findRenderObject();
      if (row is! RenderBox || !row.attached) return;
      final under =
          header.localToGlobal(Offset(0, header.size.height)).dy -
          row.localToGlobal(Offset.zero).dy;
      // Only a row whose top is behind the header, and that is not the list
      // scrolling away from a row left focused.
      if (under <= 0 || under > header.size.height) return;
      position.jumpTo(
        (position.pixels - under).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  /// Now, so the header moves with the scroll and not a frame behind it; and
  /// again after layout, because a jump lands among rows that did not exist.
  void _onScroll() {
    _measure(laidOut: false);
    _measureAfterLayout();
  }

  void _measureAfterLayout() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _measure(laidOut: true);
    });
  }

  /// The list's own sliver, found under the viewport the controller drives.
  RenderSliverMultiBoxAdaptor? _sliver() {
    final context = widget.controller.position.context.notificationContext;
    RenderSliverMultiBoxAdaptor? found;
    void visit(RenderObject object) {
      if (found != null) return;
      if (object is RenderSliverMultiBoxAdaptor) {
        found = object;
        return;
      }
      object.visitChildren(visit);
    }

    context?.findRenderObject()?.visitChildren(visit);
    return found;
  }

  /// Reads the rows the list has laid out against where the scroll position
  /// is now. Builds nothing and asks nothing: a walk over a screenful.
  void _measure({required bool laidOut}) {
    if (!mounted) return;
    final controller = widget.controller;
    if (!controller.hasClients) return _show(null, 0);
    final offset = controller.position.pixels - widget.topPadding;
    final sliver = offset <= 0 ? null : _sliver();
    if (sliver == null) return _show(null, 0);

    int? first;
    double? firstTop;
    final headerTops = <int, double>{};
    for (
      var child = sliver.firstChild;
      child != null;
      child = sliver.childAfter(child)
    ) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      final index = data.index;
      final top = data.layoutOffset;
      if (index == null || top == null || index >= widget.nodes.length) {
        continue;
      }
      if (first == null && top + child.size.height > offset) {
        first = index;
        firstTop = top;
      }
      if (widget.nodes[index] is ExplorerHeaderNode) headerTops[index] = top;
    }
    // A jump lands past every row laid out so far: that is not yet known to
    // be "nothing pinned", so what is drawn stays until the frame is.
    if (first == null) return laidOut ? _show(null, 0) : null;

    var pinned = first;
    while (pinned >= 0 && widget.nodes[pinned] is! ExplorerHeaderNode) {
      pinned--;
    }
    // Nothing above, or the header itself is still wholly on screen.
    if (pinned < 0 || (pinned == first && firstTop! >= offset)) {
      return _show(null, 0);
    }

    var shift = 0.0;
    final height = _box.currentContext?.size?.height;
    if (height != null) {
      for (final entry in headerTops.entries) {
        if (entry.key <= pinned) continue;
        final pushed = entry.value - offset - height;
        if (pushed < shift) shift = pushed;
      }
    }
    _show(pinned, shift);
  }

  void _show(int? pinned, double shift) {
    if (pinned == _pinned && shift == _shift) return;
    final appeared = pinned != null && _pinned == null;
    setState(() {
      _pinned = pinned;
      _shift = shift;
    });
    // Its height is unknown until it has been laid out once, and the push
    // from the next header is measured against it.
    if (appeared) _measureAfterLayout();
  }

  @override
  Widget build(BuildContext context) {
    final pinned = _pinned;
    if (pinned == null || pinned >= widget.nodes.length) {
      return const SizedBox.shrink();
    }
    final node = widget.nodes[pinned];
    if (node is! ExplorerHeaderNode) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: _shift,
      left: 0,
      right: 0,
      child: DecoratedBox(
        key: _box,
        // Opaque, where every other row rests transparent: rows pass under
        // it. The hairline says so.
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: ExplorerTreeRow(key: ValueKey('pinned:${node.id}'), node: node),
      ),
    );
  }
}
