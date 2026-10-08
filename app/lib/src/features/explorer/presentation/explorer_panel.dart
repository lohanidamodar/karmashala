import 'package:flutter/material.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/shell_shortcuts.dart';
import '../../../core/capabilities/capabilities.dart' show capabilitiesProvider;
import '../../projects/application/projects_controller.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../application/explorer_section_nodes.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_provider.dart';
import '../application/explorer_tree_state.dart';
import '../application/explorer_view_mode.dart';
import '../application/session_selection.dart';
import 'activity_by_day_view.dart';
import 'agents_lens.dart';
import 'explorer_header_actions.dart';
import 'explorer_keyboard.dart';
import 'explorer_scope_bar.dart';
import 'explorer_selection_actions.dart';
import 'explorer_tree_rows.dart';
import 'session_rows.dart';
import 'purge_progress_strip.dart';
import 'session_selection_bar.dart';
import 'sidebar_chrome.dart';

/// The Explorer's tree without the machines' terminal groups, which the
/// Terminals area lists. They are always the tree's tail (see
/// `buildExplorerTree`), so the cut is at the first of them.
final explorerProjectsTreeProvider = Provider.autoDispose<ExplorerTree>((ref) {
  final nodes = ref.watch(explorerTreeProvider).nodes;
  final first = nodes.indexWhere((node) => node is TerminalsHeaderNode);
  return first < 0
      ? ExplorerTree(nodes)
      : ExplorerTree(nodes.sublist(0, first));
});

/// **The Projects area** (spec §4): Project → Session, and deliberately nothing
/// else; checkout rows were removed for their git cost
/// (`checkout_scale_cost_test`). Drawn as a sidebar area: the same header as
/// Sessions and Terminals, a quiet search, one filter row (the groups, then the
/// machine), then the context groups — no bands and no rules between them.
///
/// It watches only the tree's shape and its own chrome. Every reading a row
/// draws is watched by that row, so a session's tick rebuilds one row.
class ExplorerPanel extends ConsumerWidget {
  const ExplorerPanel({this.terminals = true, super.key});

  /// Whether the machines' terminal groups end the tree. The sidebar passes
  /// false — the Terminals area is where they live; standing alone, the panel
  /// keeps them.
  final bool terminals;

  /// The +: the shell's own action when there is one, so the button and its
  /// chord cannot disagree; the dialog itself where the panel stands alone.
  static void newProject(BuildContext context) {
    if (Actions.maybeFind<NewProjectIntent>(context) != null) {
      Actions.invoke(context, const NewProjectIntent());
    } else {
      NewProjectDialog.show(context);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasProjects = ref.watch(
      sortedProjectsProvider.select((p) => p.isNotEmpty),
    );
    // Only whether the mode is on, never the ticked set.
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final showingViews = ref.watch(explorerShowingViewsProvider);
    final lens = ref.watch(explorerLensProvider);
    final search = ExplorerSearchField(
      onChanged: (query) =>
          ref.read(explorerSearchQueryProvider.notifier).set(query),
    );

    // No Agents entry row: the Sessions area is every session by what it
    // needs, one click away on the strip.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarAreaHeader(
          title: 'Projects',
          actions: const [ExplorerHeaderActions()],
          newLabel: 'New project',
          onNew: ref.watch(capabilitiesProvider.select((c) => c.mayAddProject))
              ? () => newProject(context)
              : null,
        ),
        Expanded(
          child: ExplorerLensBody(
            lens: lens,
            projects: _projectsBody(
              ref,
              hasProjects: hasProjects,
              selecting: selecting,
              showingViews: showingViews,
              search: search,
            ),
          ),
        ),
      ],
    );
  }

  /// The tree and its chrome — the Explorer as it was before any lens.
  Widget _projectsBody(
    WidgetRef ref, {
    required bool hasProjects,
    required bool selecting,
    required bool showingViews,
    required Widget search,
  }) =>
      // The search field and the list are one column to the arrow keys.
      ExplorerKeyboardScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The scope — which machine, which context — narrows the tree and
            // not the saved views, which cross both; it is not drawn over them.
            if (hasProjects && showingViews)
              search
            else if (hasProjects) ...[
              ExplorerScopeBar(search: search),
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
                    const PurgeProgressStrip(),
                    Expanded(
                      child: showingViews
                          ? const ExplorerSectionsList()
                          : hasProjects
                          ? ExplorerTreeView(
                              source: terminals
                                  ? null
                                  : explorerProjectsTreeProvider,
                            )
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

/// The Explorer's body under a [lens]. The tree stays mounted — offstage, its
/// tickers paused and out of the focus order — so switching back finds it
/// exactly as it was left, scroll position and all.
class ExplorerLensBody extends StatelessWidget {
  const ExplorerLensBody({
    required this.lens,
    required this.projects,
    super.key,
  });

  final ExplorerLens lens;
  final Widget projects;

  @override
  Widget build(BuildContext context) {
    final onTree = lens == ExplorerLens.projects;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: !onTree,
          child: TickerMode(
            enabled: onTree,
            child: ExcludeFocus(excluding: !onTree, child: projects),
          ),
        ),
        if (!onTree)
          switch (lens) {
            ExplorerLens.projects => const SizedBox.shrink(),
            ExplorerLens.agents => const AgentsPage(),
            ExplorerLens.activity => const ActivityByDayView(),
          },
      ],
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

/// The search box above the tree: quiet — the raised tone and no border at
/// rest, the focus ring only while it is being typed in — so it reads as part
/// of the list's region rather than a boxed control over it.
class ExplorerSearchField extends StatelessWidget {
  const ExplorerSearchField({required this.onChanged, super.key});

  final ValueChanged<String> onChanged;

  /// The field's line: a sidebar row's height, less the hairlines a row keeps.
  static const height = 28.0;

  static const _radius = BorderRadius.all(Radius.circular(Radii.sm));

  @override
  Widget build(BuildContext context) {
    final links = ExplorerKeyboardScope.maybeOf(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    const quiet = OutlineInputBorder(
      borderRadius: _radius,
      borderSide: BorderSide.none,
    );
    return Padding(
      // On the rows' fill edge, so the field and the rows beneath it are one
      // column, not two things that nearly line up.
      padding: const EdgeInsets.symmetric(horizontal: Sidebar.fillEdge),
      // `↓` leaves the field for the list under it — the one key of the
      // field's that a single line has no use for. Every other key is its own.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          final keys = HardwareKeyboard.instance;
          final down =
              event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.arrowDown &&
              !keys.isShiftPressed &&
              !keys.isControlPressed &&
              !keys.isMetaPressed &&
              !keys.isAltPressed;
          return down && (links?.enterList?.call() ?? false)
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        },
        child: SearchField(
          focusNode: links?.searchFocus,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: TypeSizes.field,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: tones.raised,
            hoverColor: Colors.transparent,
            constraints: const BoxConstraints(minHeight: height),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xsm + Insets.hair,
            ),
            prefixIcon: Icon(
              AppIcons.magnifyingGlass,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: height,
              minHeight: height,
            ),
            hintText: 'Search projects',
            hintStyle: theme.textTheme.bodyMedium?.copyWith(
              fontSize: TypeSizes.field,
              color: scheme.outline,
            ),
            border: quiet,
            enabledBorder: quiet,
            focusedBorder: OutlineInputBorder(
              borderRadius: _radius,
              borderSide: BorderSide(
                color: StateLayers.focusRing(scheme),
                width: StateLayers.focusRingWidth,
              ),
            ),
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// The saved sections, in place of the tree — a list of rows like it, built
/// lazily and driven by the same keys.
class ExplorerSectionsList extends ConsumerStatefulWidget {
  const ExplorerSectionsList({super.key});

  @override
  ConsumerState<ExplorerSectionsList> createState() =>
      _ExplorerSectionsListState();
}

class _ExplorerSectionsListState extends ConsumerState<ExplorerSectionsList>
    with ExplorerKeyboardList {
  @override
  List<ExplorerNode> readNodes() => ref.read(explorerSectionNodesProvider);

  @override
  Widget build(BuildContext context) {
    final nodes = ref.watch(explorerSectionNodesProvider);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: keyboard.onKey,
      child: ListView.builder(
        controller: scroll,
        padding: Sidebar.listPadding,
        itemCount: nodes.length,
        itemBuilder: (context, index) {
          final node = nodes[index];
          return ExplorerKeyboardRow(
            key: ValueKey(node.id),
            id: node.id,
            keyboard: keyboard,
            // The session is the section's own reading of it: the tree's row
            // would mount a project's session list to ask for a newer one.
            child: node is SessionRowNode
                ? NativeSessionRow(
                    session: node.session,
                    depth: node.depth,
                    subPath: node.subPath,
                    pinned: node.pinned,
                  )
                : ExplorerTreeRow(node: node, first: index == 0),
          );
        },
      ),
    );
  }
}

/// Context headers over Project → Session, built lazily.
class ExplorerTreeView extends ConsumerStatefulWidget {
  const ExplorerTreeView({this.source, super.key});

  /// The rows to draw; the Explorer's own tree when null. The Terminals area
  /// hands its own (`terminalsTreeProvider`).
  final ProviderListenable<ExplorerTree>? source;

  @override
  ConsumerState<ExplorerTreeView> createState() => _ExplorerTreeViewState();
}

class _ExplorerTreeViewState extends ConsumerState<ExplorerTreeView>
    with ExplorerKeyboardList {
  ProviderListenable<ExplorerTree> get _source =>
      widget.source ?? explorerTreeProvider;

  @override
  List<ExplorerNode> readNodes() => ref.read(_source).nodes;

  /// The row the selection was last scrolled to. A reveal happens on a
  /// *change* of selection, never on every build, or the list would fight the
  /// user's own scrolling.
  String? _revealed;

  /// Held by the selected project's row while it is on screen, so the reveal
  /// can finish exactly rather than at its estimate.
  final _selectedRow = GlobalKey();

  /// Names the list. A new name is a new list, at the top.
  int _generation = 0;

  /// Brings the selected project into view. The list is built lazily, so an
  /// off-screen row has no context to scroll to: jump by the proportion of the
  /// list it sits at, then settle exactly once it exists.
  void _revealSelected(int index, int total) {
    if (!mounted || !scroll.hasClients || total == 0) return;
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
    final position = scroll.position;
    final content = position.maxScrollExtent + position.viewportDimension;
    final guess = content * index / total - position.viewportDimension / 3;
    scroll.jumpTo(guess.clamp(0.0, position.maxScrollExtent));
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
      if (scroll.hasClients && scroll.offset != 0) {
        setState(() => _generation++);
      }
    });
    final nodes = ref.watch(_source).nodes;
    // A selection that moved — by a click, or by the pane on screen going
    // somewhere — is brought into view once, after this frame.
    final selectedProjectId = ref.watch(selectedProjectIdProvider);
    if (selectedProjectId != _revealed) {
      // A Scratch project has no row of its own: No project is its row.
      final index = nodes.indexWhere(
        (node) => switch (node) {
          ProjectNode(:final project) => project.id == selectedProjectId,
          NoProjectNode(:final projects) => projects.any(
            (p) => p.id == selectedProjectId,
          ),
          _ => false,
        },
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
      controller: scroll,
      padding: Sidebar.listPadding,
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        return ExplorerKeyboardRow(
          key: ValueKey(node.id),
          id: node.id,
          keyboard: keyboard,
          child: ExplorerTreeRow(
            node: node,
            first: index == 0,
            anchorKey:
                node is ProjectNode && node.project.id == selectedProjectId
                ? _selectedRow
                : null,
          ),
        );
      },
    );
    // The scrollbar is drawn here rather than by the list, so that it stays
    // over the pinned header instead of passing under it.
    return Scrollbar(
      controller: scroll,
      // Not a stop of its own: it hears the keys of whichever row has focus,
      // the pinned header's copy included — and so never a text field's, a
      // menu's or the terminal's, which are not under it.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: keyboard.onKey,
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
              controller: scroll,
              nodes: nodes,
              topPadding: Sidebar.listPadding.top,
              keyboard: keyboard,
            ),
          ],
        ),
      ),
    );
  }
}

/// The group header the list has scrolled past, drawn over its top edge until
/// the next header pushes it out. Not a pinned sliver: a `SliverList` per group
/// inflates a row per group off screen, and this builds none.
class ExplorerPinnedHeader extends StatefulWidget {
  const ExplorerPinnedHeader({
    required this.controller,
    required this.nodes,
    required this.topPadding,
    this.keyboard,
    super.key,
  });

  final ScrollController controller;
  final List<ExplorerNode> nodes;

  /// Told when focus is in the pinned copy, so the arrow keys move from the
  /// header it stands for.
  final ExplorerTreeKeyboard? keyboard;

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
    final keyboard = widget.keyboard;
    // `first`: it sits at the list's edge, so no gap above it.
    final Widget row = ExplorerTreeRow(
      key: ValueKey('pinned:${node.id}'),
      node: node,
      first: true,
    );
    return Positioned(
      top: _shift,
      left: 0,
      right: 0,
      child: DecoratedBox(
        key: _box,
        // Opaque, on the sidebar's own tone rather than a band of its own: the
        // rows pass under it, and nothing says it is there but the label.
        decoration: BoxDecoration(color: SurfaceTones.of(context).side),
        // The list's own side padding, so the copy sits exactly on the label.
        child: Padding(
          padding: EdgeInsets.only(
            left: Sidebar.listPadding.left,
            right: Sidebar.listPadding.right,
          ),
          child: keyboard == null
              ? row
              : ExplorerKeyboardRow(
                  key: ValueKey('pinned-keys:${node.id}'),
                  id: node.id,
                  keyboard: keyboard,
                  stop: false,
                  child: row,
                ),
        ),
      ),
    );
  }
}
