import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/row_menu.dart';
import '../../../core/widgets/reveal_on_focus.dart';

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

  /// What the row's menu is called, in the same words the button's tooltip
  /// uses, so a screen reader and a pointer are told the same thing.
  String get menuLabel => switch (this) {
    ExplorerRowKind.project => 'Project actions',
    ExplorerRowKind.checkout => 'Folder actions',
    ExplorerRowKind.session => 'Session actions',
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
///   shared by every row kind, so they cannot disagree — see
///   [_ExplorerRowFill], which is the only part of a row a hover rebuilds.
/// * **The menu.** Right-click, `Shift+F10`, the Menu key and a screen
///   reader's action all open the same one, and the `⋮` that duplicates them
///   is drawn only when it can be wanted. All of that is [RowContextMenu] now:
///   the Explorer wrote it, and every pane in the app shares it.
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

  /// The row's content.
  ///
  /// It is built when the row's *data* changes and not when a pointer crosses
  /// it: the `⋮` reads the hover state through [RowInteractionScope] rather
  /// than being handed a flag through here. The row still has to *reserve* the
  /// button's slot when it is not drawn — see [RowMenuButton] — or the text
  /// reflows the moment a pointer arrives.
  final WidgetBuilder builder;

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
  /// properly" was. Deferred to [RowMenuButton] so the verbs beside the menu
  /// cannot drift away from it.
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
          // The ink itself is invisible — it paints on the pane's Material,
          // under this tile's own fill — so hover, focus and selection are
          // painted by [_ExplorerRowFill] instead. The well is still what
          // carries the tap, the focus node and Enter-activates-the-row.
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
        // all come from here, along with the hover state the fill and the `⋮`
        // listen to. The Explorer wrote all of that first; it is shared now so
        // that every pane answers a row the same way.
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

/// The tone a row rests at, and the two states that tint it.
///
/// Its own widget because it is the *only* part of a row a hover changes: as a
/// dependent of [RowInteractionScope] it is what a pointer rebuilds, and
/// [child] — the whole card — travels through it untouched. See
/// [RowInteraction] for the lag this shape exists to fix.
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
