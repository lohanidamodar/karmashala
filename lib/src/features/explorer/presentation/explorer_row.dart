import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';

/// What a row stands for, and therefore how strongly it is drawn.
///
/// Three kinds, one per level of the tree the Explorer builds: the project
/// header, the checkouts under it (repository, worktree, unscanned folder) and
/// the session cards under those.
enum ExplorerRowKind {
  project,
  checkout,
  session;

  /// The tile's resting colour: a step of the neutral ramp per level, so depth
  /// reads as tone as well as position.
  Color surface(ColorScheme scheme) => switch (this) {
    ExplorerRowKind.project => scheme.surfaceContainerHigh,
    ExplorerRowKind.checkout => scheme.surfaceContainer,
    ExplorerRowKind.session => scheme.surfaceContainerLow,
  };
}

/// The shell every Explorer row draws itself into.
///
/// Before this existed each row kind carried its own copy of the chrome — its
/// own padding, its own selection tint, its own idea of how big a row button
/// is — and the three had drifted apart: 4px of padding on a project against 6
/// on a session, a 20px menu button on a folder row against 22 on a project.
/// The owner's report was that the cards "are not separated properly and the
/// menu button is not aligned properly"; both are the same bug, which is that
/// nothing owned a row's shape.
///
/// What this owns:
///
/// * **Separation.** A row is a tile one step up the neutral ramp from the
///   pane, with a gap of pane colour under it. The gap is taken *out of* the
///   old internal padding rather than added to it, so a list of sessions keeps
///   the pitch it always had and the rows now have edges.
/// * **Hierarchy.** [ExplorerRowKind.surface] steps the tone down with depth,
///   and the tile is indented one [indent] per level, so a session reads as
///   sitting inside its repository rather than merely after it.
/// * **State.** Selected, hovered and focused are one function of the fill,
///   shared by every row kind, so they cannot disagree.
/// * **The menu.** Right-click, `Shift+F10` and the Menu key all open the same
///   one — see [_openMenu] — and the button that duplicates them is drawn only
///   when it can be wanted; see the `menuVisible` argument to [builder].
class ExplorerRow extends StatefulWidget {
  const ExplorerRow({
    required this.kind,
    required this.depth,
    required this.selected,
    required this.builder,
    this.onTap,
    this.menuItems = const [],
    this.onMenu,
    super.key,
  });

  final ExplorerRowKind kind;
  final int depth;
  final bool selected;

  /// Null draws the row as a plain header — the companion uses a project card
  /// that way, above a list it is already inside.
  final VoidCallback? onTap;

  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String>? onMenu;

  /// The row's content.
  ///
  /// `menuVisible` says whether the overflow button should be drawn right now.
  /// The row still has to *reserve* its slot when it is false — see
  /// [ExplorerRowMenuButton] — or the text reflows the moment a pointer
  /// arrives.
  final Widget Function(BuildContext context, bool menuVisible) builder;

  /// One step of the tree, per level of depth.
  static const indent = Insets.md;

  /// What separates one row from the next.
  static const gap = Insets.xs;

  /// The accent rule that carries selection, as on the workbench tabs.
  static const _rule = 2.0;

  static const _radius = BorderRadius.all(Radius.circular(Radii.sm));

  /// The square a row-level button occupies — the menu, the `+`, the pin.
  ///
  /// One number for every row kind: a button that is 20px on one row and 22 on
  /// the next cannot sit on a shared centre-line, which is what "not aligned
  /// properly" was.
  static double slotOf(UiDensity density) =>
      density.isTouch ? Touch.target : Chrome.icon + Insets.sm;

  /// The glyph inside that slot.
  static double glyphOf(UiDensity density) =>
      density.isTouch ? Touch.icon : Chrome.icon;

  @override
  State<ExplorerRow> createState() => _ExplorerRowState();
}

class _ExplorerRowState extends State<ExplorerRow> {
  bool _hovered = false;
  bool _focused = false;

  bool get _hasMenu => widget.menuItems.isNotEmpty && widget.onMenu != null;

  /// The keyboard's way to the same menu the mouse gets from a right-click.
  ///
  /// `Shift+F10` and the Menu key are the platform convention, and they are
  /// what makes revealing the overflow button on hover honest rather than a
  /// regression: the menu is reachable from a focused row with no pointer at
  /// all.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_hasMenu) return KeyEventResult.ignored;
    final wanted =
        event.logicalKey == LogicalKeyboardKey.contextMenu ||
        (event.logicalKey == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed);
    if (!wanted) return KeyEventResult.ignored;
    final context = node.context;
    if (context == null) return KeyEventResult.ignored;
    _openMenu(context);
    return KeyEventResult.handled;
  }

  /// Opens the row's menu against the row itself.
  ///
  /// Anchored under the row's leading edge rather than at the pointer, because
  /// there is no pointer: this is the path a keyboard takes.
  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final origin = box.localToGlobal(
      Offset(Insets.lg, box.size.height),
      ancestor: overlay,
    );
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: widget.menuItems,
    );
    if (selected != null) widget.onMenu?.call(selected);
  }

  /// Resting tone, then the states, in the order they compose: what is selected
  /// stays selected while it is hovered.
  Color _fill(ColorScheme scheme) {
    var color = widget.kind.surface(scheme);
    if (widget.selected) {
      color = Color.alphaBlend(scheme.primary.withValues(alpha: 0.14), color);
    }
    if (_focused) {
      color = Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), color);
    }
    if (_hovered) {
      color = Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.06), color);
    }
    return color;
  }

  /// A floor, never a fixed height: every row still grows with its text at
  /// 200% scale instead of clipping it.
  double _minHeight(UiDensity density) {
    if (density.isTouch) return Touch.target;
    // A session card is three lines and sets its own height; the single-line
    // structural rows share the chrome's row height.
    return widget.kind == ExplorerRowKind.session ? 0 : Chrome.row;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final density = UiDensity.of(context);
    // A thumb has neither a hover nor a right-click, so on a touch-width
    // surface the button is the only way to the menu and is always drawn. A
    // pointer has both, and a permanent button on every one of a hundred rows
    // is the clutter that was reported — so there it is revealed by the pointer
    // or by the keyboard. Width, never the operating system (CLAUDE.md §6).
    final menuVisible = density.isTouch || _hovered || _focused;

    Widget content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: density.padX,
        // Half of what a row used to carry: the other half is now the gap
        // between rows, which is what makes them read as separate things.
        vertical: density.isTouch ? density.padY : Insets.xs,
      ),
      child: widget.builder(context, menuVisible),
    );
    final minHeight = _minHeight(density);
    if (minHeight > 0) {
      content = ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: content,
      );
    }

    Widget tile = DecoratedBox(
      decoration: BoxDecoration(
        color: _fill(scheme),
        borderRadius: ExplorerRow._radius,
      ),
      child: Stack(
        children: [
          InkWell(
            onTap: widget.onTap,
            onHover: (hovered) {
              if (_hovered != hovered) setState(() => _hovered = hovered);
            },
            // The ink itself is invisible — it paints on the pane's Material,
            // under this tile's own fill — so hover, focus and selection are
            // painted by [_fill] instead. The well is still what carries the
            // tap, the focus node and Enter-activates-the-row.
            borderRadius: ExplorerRow._radius,
            child: content,
          ),
          if (widget.selected)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  width: ExplorerRow._rule,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(Radii.sm),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (_hasMenu) {
      tile = ContextMenuRegion(
        menuItems: widget.menuItems,
        onSelected: widget.onMenu!,
        child: tile,
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: Insets.xs + widget.depth * ExplorerRow.indent,
        right: Insets.xs,
        bottom: ExplorerRow.gap,
      ),
      // Not a focus stop of its own: it watches the row's *subtree*, so the row
      // still reads as focused while the keyboard is inside the menu button it
      // just revealed — otherwise tabbing to that button would hide it.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        onKeyEvent: _onKey,
        child: tile,
      ),
    );
  }
}

/// The row's overflow menu, in the slot every row kind reserves for it.
///
/// One size, one glyph, one hit area, so the button lands on the same
/// centre-line whether the row is a project, a folder or a session.
///
/// [visible] false keeps the slot and draws nothing in it. That is deliberate
/// twice over: the row's text must not reflow when a pointer arrives, and an
/// absent button is absent from the focus ring too, so a hundred sessions cost
/// a hundred tab stops instead of two hundred.
///
/// **It stays while its own menu is open, and that is not a nicety.** Opening
/// the menu pushes a route whose modal barrier takes both the hover and the
/// focus off the row in the same frame, so a button drawn only for a hovering
/// pointer unmounted itself underneath its own menu — and `showMenu` drops the
/// result when the button that opened it is gone. Every choice on every row was
/// silently discarded for a mouse user; right-click and Shift+F10 worked, which
/// is exactly why the tests did not see it.
class ExplorerRowMenuButton extends StatefulWidget {
  const ExplorerRowMenuButton({
    required this.visible,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    super.key,
  });

  final bool visible;
  final String tooltip;
  final List<PopupMenuEntry<String>> items;
  final ValueChanged<String> onSelected;

  @override
  State<ExplorerRowMenuButton> createState() => _ExplorerRowMenuButtonState();
}

class _ExplorerRowMenuButtonState extends State<ExplorerRowMenuButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final slot = ExplorerRow.slotOf(density);
    return SizedBox(
      width: slot,
      height: slot,
      child: widget.visible || _open
          ? PopupMenuButton<String>(
              tooltip: widget.tooltip,
              padding: EdgeInsets.zero,
              iconSize: ExplorerRow.glyphOf(density),
              icon: const Icon(AppIcons.dotsThreeVertical),
              onOpened: () => setState(() => _open = true),
              onCanceled: () {
                if (mounted) setState(() => _open = false);
              },
              onSelected: (value) {
                if (mounted) setState(() => _open = false);
                widget.onSelected(value);
              },
              itemBuilder: (context) => widget.items,
            )
          : null,
    );
  }
}

/// A row-level verb — "new session here", "unpin", "rescan" — in the same slot
/// as [ExplorerRowMenuButton].
///
/// A verb stays visible where the overflow does not: the `+` is what a row is
/// *for*, and hiding the one affordance that starts work would trade clutter
/// for a worse problem.
class ExplorerRowAction extends StatelessWidget {
  const ExplorerRowAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final slot = ExplorerRow.slotOf(density);
    return IconButton(
      tooltip: tooltip,
      visualDensity: density.isTouch
          ? VisualDensity.standard
          : VisualDensity.compact,
      iconSize: ExplorerRow.glyphOf(density),
      constraints: BoxConstraints.tightFor(width: slot, height: slot),
      padding: EdgeInsets.zero,
      color: color,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}
