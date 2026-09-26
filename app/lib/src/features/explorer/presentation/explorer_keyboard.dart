import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../settings/application/settings_controller.dart';
import '../application/environment_terminals_providers.dart';
import '../application/explorer_sections.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_state.dart';
import '../application/session_selection.dart';
import 'explorer_project_row.dart';
import 'explorer_selection_actions.dart';
import 'session_rows.dart';

/// A list the arrow keys drive: it owns the [keyboard] over [readNodes] and
/// ties it to the search field above for as long as it is mounted.
mixin ExplorerKeyboardList<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  final scroll = ScrollController();

  /// The rows as they are when a key arrives, in the order drawn.
  List<ExplorerNode> readNodes();

  /// It holds rows by id and asks for them when a key arrives, so it outlives
  /// every rebuild and causes none.
  late final keyboard = ExplorerTreeKeyboard(
    ref: ref,
    scroll: scroll,
    readNodes: readNodes,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final links = ExplorerKeyboardScope.maybeOf(context);
    if (identical(links, keyboard.links)) return;
    keyboard.links?.enterList = null;
    keyboard.links = links;
    links?.enterList = keyboard.enter;
  }

  @override
  void dispose() {
    keyboard.links?.enterList = null;
    keyboard.dispose();
    scroll.dispose();
    super.dispose();
  }
}

/// What the search field and the list know of each other: `↓` leaves the field
/// for the first row, `↑` on the first row returns to the field. One column,
/// so the keyboard crosses it the way the eye does.
class ExplorerKeyboardLinks {
  final searchFocus = FocusNode(debugLabel: 'Explorer search');

  /// Set by the list while it is mounted. Answers whether it took focus.
  bool Function()? enterList;

  void dispose() => searchFocus.dispose();
}

/// Owns the [ExplorerKeyboardLinks] for the panel under it.
class ExplorerKeyboardScope extends StatefulWidget {
  const ExplorerKeyboardScope({required this.child, super.key});

  final Widget child;

  static ExplorerKeyboardLinks? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_KeyboardLinks>()?.links;

  @override
  State<ExplorerKeyboardScope> createState() => _ExplorerKeyboardScopeState();
}

class _ExplorerKeyboardScopeState extends State<ExplorerKeyboardScope> {
  final _links = ExplorerKeyboardLinks();

  @override
  void dispose() {
    _links.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _KeyboardLinks(links: _links, child: widget.child);
}

class _KeyboardLinks extends InheritedWidget {
  const _KeyboardLinks({required this.links, required super.child});

  final ExplorerKeyboardLinks links;

  @override
  bool updateShouldNotify(_KeyboardLinks old) => old.links != links;
}

/// What a typed letter is matched against: the words the row is read by.
String explorerNodeTitle(ExplorerNode node) => switch (node) {
  final ContextHeaderNode node => node.label,
  final TerminalsHeaderNode node => node.label,
  final SectionHeaderNode node => node.section.name,
  final ProjectNode node => node.project.name,
  final SessionRowNode node => node.session.title,
  final ImportedRowNode node => node.session.displayTitle,
  final TerminalRowNode node => node.terminal.label,
  HintNode() => '',
};

/// Whether the arrow keys stop on [node]: every row with a verb of its own. A
/// line of prose has none, and neither has a terminal that has ended.
bool isExplorerKeyboardStop(ExplorerNode node) => switch (node) {
  HintNode() => false,
  final TerminalRowNode node => node.terminal.running,
  _ => true,
};

/// Whether [node] folds, and which way it is now; null for a row that does not.
bool? explorerNodeExpanded(ExplorerNode node) => switch (node) {
  final ExplorerHeaderNode node => node.expanded,
  final ProjectNode node => node.expanded,
  _ => null,
};

/// The row `←` goes to from [index]: a session's project (or the session it
/// came from), a project's context header, a terminal's `TERMINALS`. -1 at the
/// top — a header, or a project in a list with no contexts.
int explorerParentIndex(List<ExplorerNode> nodes, int index) {
  final node = nodes[index];
  if (node is ExplorerHeaderNode) return -1;
  for (var above = index - 1; above >= 0; above--) {
    final candidate = nodes[above];
    if (node is TerminalRowNode) {
      if (candidate is TerminalsHeaderNode) return above;
    } else if (node.depth == 0) {
      if (candidate is ContextHeaderNode) return above;
      if (candidate is TerminalsHeaderNode) return -1;
    } else if (candidate is! HintNode && candidate.depth < node.depth) {
      return above;
    }
  }
  return -1;
}

/// The next stop from [index] going [direction] (+1 or -1), or null at the end.
int? explorerNextStop(List<ExplorerNode> nodes, int index, int direction) {
  for (
    var next = index + direction;
    next >= 0 && next < nodes.length;
    next += direction
  ) {
    if (isExplorerKeyboardStop(nodes[next])) return next;
  }
  return null;
}

/// Where typing [typed] goes from [index], or null when no title starts with
/// it. A new word looks from the next row on, so a letter typed again walks
/// the rows that share it; a longer word may stay where it is. Wraps.
int? explorerTypeAheadTarget(
  List<ExplorerNode> nodes,
  int index,
  String typed,
) {
  if (typed.isEmpty || nodes.isEmpty) return null;
  final repeated = typed.split('').toSet().length == 1;
  final prefix = (repeated ? typed[0] : typed).toLowerCase();
  final start = repeated ? index + 1 : index;
  for (var step = 0; step < nodes.length; step++) {
    final at = (start + step) % nodes.length;
    final node = nodes[at];
    if (isExplorerKeyboardStop(node) &&
        explorerNodeTitle(node).toLowerCase().startsWith(prefix)) {
      return at;
    }
  }
  return null;
}

/// Opens or folds a machine's `Terminals`. Opening asks the machine; closing
/// asks nothing, and the answer is never refreshed on a timer (§19).
void toggleExplorerTerminals(WidgetRef ref, String environmentId) {
  final opening = ref
      .read(explorerExpandedTerminalsProvider.notifier)
      .toggle(environmentId);
  if (opening) {
    ref.read(environmentTerminalsProvider(environmentId).notifier).refresh();
  }
}

/// **The Explorer's arrow keys**, over the rows in the order the list draws
/// them: `↑`/`↓` a row, `Home`/`End`, `Page Up`/`Page Down` a screen, `→` to
/// open and then step in, `←` to fold and then step out, Shift with an arrow
/// to extend a selection, and letters to go to a title.
///
/// The list is lazy, so a row is held by **id**: a built row has registered
/// the [FocusNode] its one stop takes, and an unbuilt one is scrolled to until
/// it has. Nothing here rebuilds anything — moving focus is two rows'
/// `RowInteraction` and no `setState`.
class ExplorerTreeKeyboard {
  ExplorerTreeKeyboard({
    required this.ref,
    required this.scroll,
    required this.readNodes,
  });

  final WidgetRef ref;
  final ScrollController scroll;

  /// The tree as it is when a key arrives, not as it was when a row was built.
  final List<ExplorerNode> Function() readNodes;

  /// The search field above, when there is one.
  ExplorerKeyboardLinks? links;

  final _stops = <String, FocusNode>{};

  var _typed = '';
  Timer? _typedReset;
  var _disposed = false;

  /// How many times an unbuilt row is scrolled towards before giving up: each
  /// lands nearer, from an estimate made of the rows built around the last.
  static const _maxJumps = 8;

  void dispose() {
    _disposed = true;
    _typedReset?.cancel();
  }

  void register(String id, FocusNode stop) => _stops[id] = stop;

  void unregister(String id, FocusNode stop) {
    if (identical(_stops[id], stop)) _stops.remove(id);
  }

  /// From the search field: the first row. False when there is none.
  bool enter() {
    final nodes = readNodes();
    final first = explorerNextStop(nodes, -1, 1);
    if (first == null) return false;
    _focus(nodes[first].id);
    return true;
  }

  KeyEventResult onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    // Which row has focus is read off the tree when a key arrives — the row,
    // or the pinned copy of a header, above whatever holds it. Asked per key
    // rather than tracked per row, so a row carries no listener for it.
    final primary = FocusManager.instance.primaryFocus?.context;
    final id = primary
        ?.findAncestorWidgetOfExactType<ExplorerKeyboardRow>()
        ?.id;
    if (primary == null || id == null) return KeyEventResult.ignored;
    // A text field inside a row keeps every key that is its own.
    if (primary.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f2) {
      return event is KeyDownEvent && _rename(primary)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    final nodes = readNodes();
    final index = nodes.indexWhere((node) => node.id == id);
    if (index < 0) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.arrowDown) {
      return _step(nodes, index, 1, extend: keys.isShiftPressed);
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      return _step(nodes, index, -1, extend: keys.isShiftPressed);
    }
    if (key == LogicalKeyboardKey.home) {
      return _go(nodes, explorerNextStop(nodes, -1, 1));
    }
    if (key == LogicalKeyboardKey.end) {
      return _go(nodes, explorerNextStop(nodes, nodes.length, -1));
    }
    if (key == LogicalKeyboardKey.pageDown) return _page(nodes, index, 1);
    if (key == LogicalKeyboardKey.pageUp) return _page(nodes, index, -1);
    if (key == LogicalKeyboardKey.arrowRight) return _right(nodes, index);
    if (key == LogicalKeyboardKey.arrowLeft) return _left(nodes, index);

    final character = event.character;
    // Printable, and not Space: that is the row's own activation.
    if (character != null &&
        character.length == 1 &&
        character.codeUnitAt(0) > 0x20 &&
        character.codeUnitAt(0) != 0x7f) {
      return _type(nodes, index, character);
    }
    return KeyEventResult.ignored;
  }

  /// `F2`, as the menus say: a session's "Rename", a project's editor. Read
  /// off the row that is drawn, so it names what the row names now.
  bool _rename(BuildContext focused) {
    var handled = false;
    focused.visitAncestorElements((element) {
      final row = element.widget;
      if (row is NativeSessionRow) {
        unawaited(renameNativeSession(element, ref, row.session));
      } else if (row is ImportedSessionRow) {
        unawaited(renameImportedSession(element, ref, row.session));
      } else if (row is ExplorerProjectRow) {
        ProjectRowActions(ref, element, row.project).onMenu('edit');
      } else {
        return row is! ExplorerKeyboardRow;
      }
      handled = true;
      return false;
    });
    return handled;
  }

  KeyEventResult _go(List<ExplorerNode> nodes, int? index) {
    if (index != null) _focus(nodes[index].id);
    return KeyEventResult.handled;
  }

  KeyEventResult _step(
    List<ExplorerNode> nodes,
    int index,
    int direction, {
    required bool extend,
  }) {
    final next = explorerNextStop(nodes, index, direction);
    if (next == null) {
      // Above the first row is the search field, in the same column.
      final search = links?.searchFocus;
      if (direction < 0 && search != null && search.context != null) {
        search.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (extend) _extendSelection(nodes, index, next);
    return _go(nodes, next);
  }

  /// Shift and an arrow, in selection mode: the row left is ticked if it was
  /// not, and the range from the anchor reaches the row arrived at — in the
  /// order drawn, like a Shift-click. A header on the way is only passed.
  void _extendSelection(List<ExplorerNode> nodes, int from, int to) {
    final selection = ref.read(sessionSelectionProvider);
    if (!selection.active) return;
    final target = _selectable(nodes[to]);
    if (target == null) return;
    final controller = ref.read(sessionSelectionProvider.notifier);
    final origin = _selectable(nodes[from]);
    if (origin != null &&
        origin.kind == target.kind &&
        !selection.contains(origin.id)) {
      controller.toggle(origin.id, kind: origin.kind);
    }
    controller.extendTo(
      target.id,
      kind: target.kind,
      order: selectableOrder(nodes, target.kind),
    );
  }

  static ({String id, SelectionKind kind})? _selectable(ExplorerNode node) =>
      switch (node) {
        final ProjectNode node => (
          id: node.project.id,
          kind: SelectionKind.projects,
        ),
        final SessionRowNode node => (
          id: node.session.id,
          kind: SelectionKind.sessions,
        ),
        final ImportedRowNode node => (
          id: node.session.id,
          kind: SelectionKind.sessions,
        ),
        _ => null,
      };

  KeyEventResult _right(List<ExplorerNode> nodes, int index) {
    if (explorerNodeExpanded(nodes[index]) == false) {
      _toggle(nodes[index]);
      return KeyEventResult.handled;
    }
    final next = explorerNextStop(nodes, index, 1);
    if (next != null && explorerParentIndex(nodes, next) == index) {
      _focus(nodes[next].id);
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _left(List<ExplorerNode> nodes, int index) {
    if (explorerNodeExpanded(nodes[index]) ?? false) {
      _toggle(nodes[index]);
      return KeyEventResult.handled;
    }
    final parent = explorerParentIndex(nodes, index);
    if (parent >= 0) _focus(nodes[parent].id);
    return KeyEventResult.handled;
  }

  /// Folds or unfolds, and nothing else: selecting a project is Enter's.
  void _toggle(ExplorerNode node) {
    switch (node) {
      case ContextHeaderNode():
        ref
            .read(settingsControllerProvider.notifier)
            .toggleExplorerNodeCollapsed(node.id);
      case TerminalsHeaderNode():
        toggleExplorerTerminals(ref, node.environmentId);
      case SectionHeaderNode():
        ref
            .read(explorerSectionsProvider.notifier)
            .toggleCollapsed(node.section.id);
      case ProjectNode():
        ref
            .read(explorerExpandedProjectsProvider.notifier)
            .toggle(node.project.id);
      default:
    }
  }

  KeyEventResult _type(List<ExplorerNode> nodes, int index, String character) {
    _typedReset?.cancel();
    _typedReset = Timer(Latency.typeAhead, () => _typed = '');
    _typed += character;
    final target = explorerTypeAheadTarget(nodes, index, _typed);
    if (target != null && target != index) _focus(nodes[target].id);
    return KeyEventResult.handled;
  }

  /// A screen, not a row: the list moves by its own height first, and focus
  /// lands on the row that is then where the focused one was.
  KeyEventResult _page(List<ExplorerNode> nodes, int index, int direction) {
    final here = _extentOf(_stops[nodes[index].id]);
    if (here == null || !scroll.hasClients) {
      return _step(nodes, index, direction, extend: false);
    }
    final position = scroll.position;
    final wanted = here.top + direction * position.viewportDimension;
    final target = (position.pixels + direction * position.viewportDimension)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final id = nodes[index].id;
    if (target == position.pixels) {
      _landNear(id, wanted, direction);
    } else {
      position.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _landNear(id, wanted, direction),
      );
    }
    return KeyEventResult.handled;
  }

  /// Focuses the built stop whose top is nearest [wanted], [direction] of the
  /// row [fromId] — or the last one that way when nothing is.
  void _landNear(String fromId, double wanted, int direction) {
    if (_disposed) return;
    final nodes = readNodes();
    final from = nodes.indexWhere((node) => node.id == fromId);
    if (from < 0) return;
    int? best;
    var bestDistance = double.infinity;
    for (final entry in _stops.entries) {
      final extent = _extentOf(entry.value);
      if (extent == null || extent.index >= nodes.length) continue;
      if ((extent.index - from).sign != direction) continue;
      if (nodes[extent.index].id != entry.key) continue;
      final distance = (extent.top - wanted).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = extent.index;
      }
    }
    best ??= explorerNextStop(nodes, from, direction);
    if (best != null) _focus(nodes[best].id);
  }

  /// Where a built row sits in the list: its index and its scroll extent.
  static ({int index, double top, double bottom})? _extentOf(FocusNode? stop) {
    RenderObject? object = stop?.context?.findRenderObject();
    while (object != null &&
        object.parentData is! SliverMultiBoxAdaptorParentData) {
      object = object.parent;
    }
    if (object is! RenderBox || !object.hasSize) return null;
    final data = object.parentData! as SliverMultiBoxAdaptorParentData;
    final index = data.index;
    final top = data.layoutOffset;
    if (index == null || top == null) return null;
    return (index: index, top: top, bottom: top + object.size.height);
  }

  /// Focuses the row [id]. A built row takes it now, and `RevealOnFocus` and
  /// the pinned header bring it clear into view. An unbuilt one has no context
  /// to scroll to and rows have no fixed extent, so the list jumps to where
  /// the rows built now say it should be, and looks again after the frame.
  void _focus(String id, {int attempt = 0}) {
    if (_disposed) return;
    final stop = _stops[id];
    if (stop != null && stop.context != null) {
      stop.requestFocus();
      return;
    }
    if (attempt >= _maxJumps || !scroll.hasClients) return;
    final index = readNodes().indexWhere((node) => node.id == id);
    if (index < 0) return;

    ({int index, double top, double bottom})? first;
    ({int index, double top, double bottom})? last;
    for (final built in _stops.values) {
      final extent = _extentOf(built);
      if (extent == null) continue;
      if (first == null || extent.index < first.index) first = extent;
      if (last == null || extent.index > last.index) last = extent;
    }
    if (first == null || last == null) return;
    final position = scroll.position;
    final view = position.viewportDimension;
    final each = (last.bottom - first.top) / (last.index - first.index + 1);
    final guess = index < first.index
        ? first.top - (first.index - index) * each - view / 3
        : last.bottom + (index - last.index) * each - view * 2 / 3;
    final target = guess.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    position.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focus(id, attempt: attempt + 1),
    );
  }
}

/// One row of the list, as the keyboard holds it: it names the row ([id]) for
/// whatever has focus beneath it, and — as a [stop] — hands that row the
/// [FocusNode] that `keyboard` focuses it by. The pinned copy of a header is
/// not a stop: the header itself is, further up the list.
class ExplorerKeyboardRow extends StatefulWidget {
  const ExplorerKeyboardRow({
    required this.id,
    required this.keyboard,
    required this.child,
    this.stop = true,
    super.key,
  });

  final String id;
  final ExplorerTreeKeyboard keyboard;
  final bool stop;
  final Widget child;

  @override
  State<ExplorerKeyboardRow> createState() => _ExplorerKeyboardRowState();
}

class _ExplorerKeyboardRowState extends State<ExplorerKeyboardRow> {
  late final _stop = FocusNode(debugLabel: widget.id);

  @override
  void initState() {
    super.initState();
    if (widget.stop) widget.keyboard.register(widget.id, _stop);
  }

  @override
  void didUpdateWidget(ExplorerKeyboardRow old) {
    super.didUpdateWidget(old);
    if (old.id == widget.id && old.keyboard == widget.keyboard) return;
    if (old.stop) old.keyboard.unregister(old.id, _stop);
    if (widget.stop) widget.keyboard.register(widget.id, _stop);
  }

  @override
  void dispose() {
    if (widget.stop) {
      widget.keyboard.unregister(widget.id, _stop);
      _stop.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.stop
      ? ExplorerRowFocus(node: _stop, child: widget.child)
      : widget.child;
}
