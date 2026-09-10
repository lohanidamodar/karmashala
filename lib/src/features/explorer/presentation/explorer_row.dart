import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';

/// What a row stands for, and therefore how strongly it is drawn — one kind
/// per level of the tree: project, checkout, session.
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

  /// What the row's menu is called, in the same words the button's tooltip
  /// uses, so a screen reader and a pointer are told the same thing.
  String get menuLabel => switch (this) {
    ExplorerRowKind.project => 'Project actions',
    ExplorerRowKind.checkout => 'Folder actions',
    ExplorerRowKind.session => 'Session actions',
  };
}

/// The shell every Explorer row draws itself into: separation, hierarchy, the
/// one selected/hovered/focused fill, and the menu. Before it each row kind
/// carried its own padding and button size, and the three had drifted.
class ExplorerRow extends StatelessWidget {
  const ExplorerRow({
    required this.kind,
    required this.depth,
    required this.selected,
    required this.builder,
    this.onTap,
    this.menuItemsBuilder,
    this.onMenu,
    super.key,
  });

  final ExplorerRowKind kind;
  final int depth;
  final bool selected;

  /// Null draws the row as a plain header — the companion uses a project card
  /// that way, above a list it is already inside.
  final VoidCallback? onTap;

  /// Called when the menu opens, and not before. Null for a row with no menu.
  final RowMenuItemBuilder? menuItemsBuilder;

  final ValueChanged<String>? onMenu;

  /// The row's content, built when the row's *data* changes and not when a
  /// pointer crosses it. It must still *reserve* the `⋮` slot when the button
  /// is not drawn (see [RowMenuButton]) or the text reflows on hover.
  final WidgetBuilder builder;

  /// One step of the tree, per level of depth.
  static const indent = Insets.md;

  /// What separates one row from the next.
  static const gap = Insets.xs;

  /// The accent rule that carries selection, as on the workbench tabs.
  static const _rule = 2.0;

  static const _radius = BorderRadius.all(Radius.circular(Radii.sm));

  /// The square a row-level button occupies — the menu, the `+`, the pin. One
  /// number for every row kind, or they cannot share a centre-line.
  static double slotOf(UiDensity density) => RowMenuButton.slotOf(density);

  /// The glyph inside that slot.
  static double glyphOf(UiDensity density) => RowMenuButton.glyphOf(density);

  bool get _hasMenu => menuItemsBuilder != null && onMenu != null;

  /// A floor, never a fixed height: every row still grows with its text at
  /// 200% scale instead of clipping it.
  double _minHeight(UiDensity density) {
    if (density.isTouch) return Touch.target;
    // A session card is three lines and sets its own height; the single-line
    // structural rows share the chrome's row height.
    return kind == ExplorerRowKind.session ? 0 : Chrome.row;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final density = UiDensity.of(context);

    Widget content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: density.padX,
        // Half of what a row used to carry: the other half is now the gap
        // between rows, which is what makes them read as separate things.
        vertical: density.isTouch ? density.padY : Insets.xs,
      ),
      child: Builder(builder: builder),
    );
    final minHeight = _minHeight(density);
    if (minHeight > 0) {
      content = ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: content,
      );
    }

    // Built once, and handed to the fill as a `child` it passes straight
    // through: a hover repaints the tone and rebuilds nothing inside it.
    final stack = Stack(
      children: [
        InkWell(
          onTap: onTap,
          // The ink is invisible — it paints on the pane's Material, under this
          // tile's fill — so [_ExplorerRowFill] paints the states instead.
          borderRadius: ExplorerRow._radius,
          child: content,
        ),
        if (selected)
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
    );

    // The Explorer's body is one lazy `ListView`, so a row Tab reaches may be a
    // cached one above the viewport that forward traversal will not scroll back
    // to on its own. See [RevealOnFocus].
    return RevealOnFocus(
      child: Padding(
        padding: EdgeInsets.only(
          left: Insets.xs + depth * ExplorerRow.indent,
          right: Insets.xs,
          bottom: ExplorerRow.gap,
        ),
        // Right-click, `Shift+F10`, the Menu key and the screen-reader action
        // all come from here, with the hover state the fill and the `⋮` read.
        child: RowContextMenu(
          menuLabel: kind.menuLabel,
          itemBuilder: _hasMenu ? menuItemsBuilder : null,
          onSelected: onMenu ?? (_) {},
          builder: (context) =>
              _ExplorerRowFill(kind: kind, selected: selected, child: stack),
        ),
      ),
    );
  }
}

/// The tone a row rests at, and the two states that tint it. Its own widget
/// because it is the *only* part of a row a hover changes: [child] — the whole
/// card — travels through it untouched.
class _ExplorerRowFill extends StatelessWidget {
  const _ExplorerRowFill({
    required this.kind,
    required this.selected,
    required this.child,
  });

  final ExplorerRowKind kind;
  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final interaction = RowInteractionScope.maybeOf(context);
    // Resting tone, then the states, in the order they compose: what is
    // selected stays selected while it is hovered.
    var color = kind.surface(scheme);
    if (selected) {
      color = Color.alphaBlend(scheme.primary.withValues(alpha: 0.14), color);
    }
    if (interaction?.focused ?? false) {
      color = Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), color);
    }
    if (interaction?.hovered ?? false) {
      color = Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.06), color);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: ExplorerRow._radius,
      ),
      child: child,
    );
  }
}

/// A row-level verb — "new session here", "unpin", "rescan" — in the same slot
/// as [ExplorerRowMenuButton]. A verb stays visible where the overflow does
/// not: hiding the one affordance that starts work is the worse trade.
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
