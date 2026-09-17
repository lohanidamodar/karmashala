import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';
import '../row_menu.dart';
import '../reveal_on_focus.dart';

/// What a row stands for. Under a pointer every kind is drawn alike — flat,
/// one gutter, one right-hand column; the kind names the menu and, under a
/// thumb, the tile's tone.
enum ExplorerRowKind {
  project,
  checkout,
  session,

  /// A context's header, a machine's `TERMINALS`, a saved section — a row that
  /// folds the rows under it.
  group,

  /// A shell under a machine's `Terminals`.
  terminal;

  /// The tile's resting colour under a thumb, one step of the ramp per level.
  /// A pointer row rests transparent (design-direction S3).
  Color surface(ColorScheme scheme) => switch (this) {
    ExplorerRowKind.project ||
    ExplorerRowKind.group => scheme.surfaceContainerHigh,
    ExplorerRowKind.checkout => scheme.surfaceContainer,
    ExplorerRowKind.session ||
    ExplorerRowKind.terminal => scheme.surfaceContainerLow,
  };

  /// What the row's menu is called, in the same words the button's tooltip
  /// uses, so a screen reader and a pointer are told the same thing.
  String get menuLabel => switch (this) {
    ExplorerRowKind.project => 'Project actions',
    ExplorerRowKind.checkout => 'Folder actions',
    ExplorerRowKind.session => 'Session actions',
    ExplorerRowKind.group => 'Group actions',
    ExplorerRowKind.terminal => 'Terminal actions',
  };
}

/// The shell every Explorer row draws itself into: the indent, the one
/// selected/hovered/focused fill, and the menu.
///
/// Under a pointer the geometry is one model for every kind:
/// `[depth × indent][disclosure][glyph][gap] title … [trailing]`, with the fill
/// spanning the pane and only the content indented.
class ExplorerRow extends StatelessWidget {
  const ExplorerRow({
    required this.kind,
    required this.depth,
    required this.selected,
    required this.builder,
    this.onTap,
    this.menuItemsBuilder,
    this.onMenu,
    this.settled = false,
    this.expanded,
    super.key,
  });

  final ExplorerRowKind kind;
  final int depth;
  final bool selected;

  /// Whether the rows under this one are drawn, for a row that folds; null for
  /// one that does not. Said to a screen reader — the caret is the row's own.
  final bool? expanded;

  /// Null draws the row as a plain header — the companion uses a project card
  /// that way, above a list it is already inside.
  final VoidCallback? onTap;

  /// Called when the menu opens, and not before. Null for a row with no menu.
  final RowMenuItemBuilder? menuItemsBuilder;

  final ValueChanged<String>? onMenu;

  /// A session that ended and has been seen: its content is drawn at
  /// [settledOpacity], so what still needs you stands out.
  final bool settled;

  /// The row's content, built when the row's *data* changes and not when a
  /// pointer crosses it.
  final WidgetBuilder builder;

  /// One step of the tree, per level of depth.
  static const indent = Insets.md;

  /// The column a disclosure caret sits in, reserved on rows that have none.
  static const disclosureSlot = Chrome.icon;

  /// The column a row's one leading glyph sits in: folder, stack, status.
  static const glyphSlot = Chrome.icon;

  /// Between the glyph column and the title.
  static const textGap = Insets.xs;

  /// Everything left of a row's title at depth zero. Second lines hang here.
  static const lead = disclosureSlot + glyphSlot + textGap;

  /// The selection box's column, drawn ahead of [lead] while selecting: a
  /// compact checkbox's 32px and a gap.
  static const tickSlot = disclosureSlot + glyphSlot + textGap;

  static const disclosureSize = Chrome.iconSmall;
  static const glyphSize = Chrome.iconAction;

  /// The fill's margin from the pane's edges.
  static const inset = Insets.xs;

  /// Kept clear inside a pointer row's right edge: the scrollbar's lane. The
  /// fill still spans the pane — only the content stays out from under the
  /// thumb, so a count is never drawn beneath it.
  static const scrollbarGutter = Insets.sm;

  /// What separates one row from the next under a thumb, and the list's own
  /// padding top and bottom.
  static const gap = Insets.xs;

  /// Under a pointer rows sit one hairline apart: flat rows need no gutter.
  static double gapOf(UiDensity density) => density.isTouch ? gap : Insets.hair;

  static const settledOpacity = 0.6;

  /// The `·` between clauses of a meta line, over the muted ink.
  static const separatorAlpha = 0.5;

  static const _radius = BorderRadius.all(Radius.circular(Radii.sm));

  /// The square a row-level button occupies — the menu, the `+`. One number for
  /// every row kind, or they cannot share a centre-line.
  static double slotOf(UiDensity density) => RowMenuButton.slotOf(density);

  /// The glyph inside that slot.
  static double glyphOf(UiDensity density) => RowMenuButton.glyphOf(density);

  /// Where depth zero's disclosure column starts, from the pane's left edge.
  static double contentStartOf(UiDensity density) => inset + density.padX;

  /// The right-hand column every row kind ends in: two button slots wide, grown
  /// with the text scale so an age still fits it.
  static double trailingWidthOf(BuildContext context) {
    final slots = slotOf(UiDensity.of(context)) * 2;
    return math.max(slots, MediaQuery.textScalerOf(context).scale(slots));
  }

  /// The right-hand column when it says its count in words — `18 projects`,
  /// `12 sessions`. Right-aligned like the bare number, so it grows leftwards
  /// and every row still ends on one edge.
  static double wordsWidthOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(wordsColumn);

  /// Wide enough for `118 projects` in the muted hand.
  static const wordsColumn = 84.0;

  /// What a title keeps before a count may be spelled out beside it. Under it
  /// the name wins and the count is the bare number.
  static const wordsTitleFloor = 112.0;

  /// A floor, never a fixed height: every row still grows with its text.
  double _minHeight(UiDensity density) {
    if (density.isTouch) return Touch.target;
    return kind == ExplorerRowKind.session ? 0 : Chrome.row;
  }

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final touch = density.isTouch;

    Widget body = Builder(builder: builder);
    if (settled) body = Opacity(opacity: settledOpacity, child: body);
    Widget content = Padding(
      padding: touch
          ? EdgeInsets.symmetric(
              horizontal: density.padX,
              vertical: density.padY,
            )
          : EdgeInsets.fromLTRB(
              density.padX + depth * indent,
              kind == ExplorerRowKind.session ? Insets.xs : Insets.hair,
              density.padX + scrollbarGutter,
              kind == ExplorerRowKind.session ? Insets.xs : Insets.hair,
            ),
      child: body,
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
    Widget row = InkWell(
      onTap: onTap,
      focusNode: ExplorerRowFocus.maybeOf(context),
      borderRadius: _radius,
      child: content,
    );
    // On the row's own node, so a screen reader hears "collapsed" with the
    // name and not as a stray child.
    if (expanded != null) row = Semantics(expanded: expanded, child: row);

    // The Explorer's body is one lazy `ListView`, so a row Tab reaches may be a
    // cached one above the viewport. See [RevealOnFocus].
    return RevealOnFocus(
      child: Padding(
        padding: EdgeInsets.only(
          left: inset + (touch ? depth * indent : 0),
          right: inset,
          bottom: gapOf(density),
        ),
        child: RowContextMenu(
          menuLabel: kind.menuLabel,
          itemBuilder: menuItemsBuilder != null && onMenu != null
              ? menuItemsBuilder
              : null,
          onSelected: onMenu ?? (_) {},
          builder: (context) =>
              _ExplorerRowFill(kind: kind, selected: selected, child: row),
        ),
      ),
    );
  }
}

/// Hands the row beneath it the [FocusNode] its one stop takes, so a list that
/// moves focus by key — arrows, Home, a typed letter — can focus a row it
/// holds only by id. Without one a row makes its own, as ever.
class ExplorerRowFocus extends InheritedWidget {
  const ExplorerRowFocus({required this.node, required super.child, super.key});

  final FocusNode node;

  /// Read, not depended on: the node is the same for the row's whole life.
  static FocusNode? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ExplorerRowFocus>()?.node;

  @override
  bool updateShouldNotify(ExplorerRowFocus old) => old.node != node;
}

/// The only part of a row a hover changes: [child] travels through untouched.
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
    final touch = UiDensity.of(context).isTouch;
    final interaction = RowInteractionScope.maybeOf(context);
    // Resting tone, then the states in the order they compose. Focus is a
    // ring, not a fill.
    Color? color = touch ? kind.surface(scheme) : null;
    Color layer(Color over) =>
        color == null ? over : Color.alphaBlend(over, color);
    if (selected) color = layer(StateLayers.selected(scheme));
    if (interaction?.hovered ?? false) color = layer(StateLayers.hover(scheme));
    final focused = interaction?.focused ?? false;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: ExplorerRow._radius,
        border: focused
            ? Border.all(
                color: StateLayers.focusRing(scheme),
                width: StateLayers.focusRingWidth,
              )
            : null,
      ),
      child: child,
    );
  }
}

/// A row's disclosure and glyph columns plus the gap before its title — the
/// same 36px on every kind, so carets and glyphs form one column per depth.
class ExplorerRowLead extends StatelessWidget {
  const ExplorerRowLead({
    this.expanded,
    this.glyph,
    this.tick,
    this.onDisclosure,
    this.glyphColumn = true,
    super.key,
  });

  /// False for a group label, which has no glyph to draw: its words start
  /// right after the caret instead of a column further in.
  final bool glyphColumn;

  /// Null reserves the disclosure column and draws nothing in it.
  final bool? expanded;

  /// Centred in [ExplorerRow.glyphSlot]; size it [ExplorerRow.glyphSize].
  final Widget? glyph;

  /// A selection box, in its own column ahead of the disclosure while a
  /// selection is open, so carets and glyphs stay where they were relative to
  /// each other.
  final Widget? tick;

  /// Makes the caret its own target — folding a row without the row's tap.
  final VoidCallback? onDisclosure;

  /// How wide this lead is: [ExplorerRow.lead], plus [ExplorerRow.tickSlot]
  /// while a tick is drawn.
  double get width =>
      ExplorerRow.lead -
      (glyphColumn ? 0 : ExplorerRow.glyphSlot) +
      (tick == null ? 0 : ExplorerRow.tickSlot);

  @override
  Widget build(BuildContext context) {
    final expanded = this.expanded;
    final tick = this.tick;
    Widget? caret = expanded == null
        ? null
        : Center(
            child: Icon(
              expanded ? AppIcons.caretDown : AppIcons.caretRight,
              size: ExplorerRow.disclosureSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
    if (caret != null && onDisclosure != null) {
      caret = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDisclosure,
          child: caret,
        ),
      );
    }
    return SizedBox(
      width: width,
      child: Row(
        children: [
          if (tick != null)
            SizedBox(
              width: ExplorerRow.tickSlot,
              child: Center(child: tick),
            ),
          SizedBox(width: ExplorerRow.disclosureSlot, child: caret),
          // Square, and a wider badge is scaled into it rather than pushing
          // the title off the row.
          if (glyphColumn)
            SizedBox.square(
              dimension: ExplorerRow.glyphSlot,
              child: glyph == null
                  ? null
                  : Center(
                      child: FittedBox(fit: BoxFit.scaleDown, child: glyph),
                    ),
            ),
          const SizedBox(width: ExplorerRow.textGap),
        ],
      ),
    );
  }
}

/// One line of a pointer row: [ExplorerRowLead], the flexible [title], and the
/// right-hand [trailing] column at [ExplorerRow.trailingWidthOf] — capped at
/// half of what the lead leaves, so a 200px pane at 2× text still fits.
///
/// A trailing column that has [ExplorerRowTrailing.wideMeta] says it instead
/// of the bare number while the title keeps [ExplorerRow.wordsTitleFloor].
class ExplorerRowLine extends StatelessWidget {
  const ExplorerRowLine({
    required this.lead,
    required this.title,
    this.trailing,
    super.key,
  });

  final ExplorerRowLead lead;
  final Widget title;
  final ExplorerRowTrailing? trailing;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    if (trailing == null) {
      return Row(
        children: [
          lead,
          Expanded(child: title),
        ],
      );
    }
    final wanted = ExplorerRow.trailingWidthOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = math.max(0.0, constraints.maxWidth - lead.width);
        final words = ExplorerRow.wordsWidthOf(context);
        final inWords =
            trailing.wideMeta != null &&
            room - words >=
                MediaQuery.textScalerOf(
                  context,
                ).scale(ExplorerRow.wordsTitleFloor);
        final width = inWords ? words : math.min(wanted, room / 2);
        return Row(
          children: [
            lead,
            Expanded(child: title),
            SizedBox(
              width: width,
              child: inWords ? trailing.inWords() : trailing,
            ),
          ],
        );
      },
    );
  }
}

/// The right-hand column: a count or an age at rest, the row's verbs in its
/// place while a pointer or the keyboard is on the row. [action] and [menu]
/// have fixed slots, so every `+` in the tree shares one centre-line.
class ExplorerRowTrailing extends StatelessWidget {
  const ExplorerRowTrailing({
    this.meta,
    this.wideMeta,
    this.action,
    this.menu,
    super.key,
  });

  /// Right-aligned, scaled down rather than ellipsised: half a number is wrong.
  final Widget? meta;

  /// [meta] in words — `18 projects` for `18` — drawn in its place by
  /// [ExplorerRowLine] while the row has the room.
  final Widget? wideMeta;

  /// This column with [wideMeta] as its meta. The verbs keep their slots.
  ExplorerRowTrailing inWords() =>
      ExplorerRowTrailing(meta: wideMeta ?? meta, action: action, menu: menu);

  /// The row's verb — `+` — in the slot left of [menu].
  final Widget? action;

  /// The `⋮`, in the rightmost slot.
  final Widget? menu;

  @override
  Widget build(BuildContext context) => _TrailingSwap(
    meta: meta == null
        ? null
        : Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: meta,
            ),
          ),
    actions: action == null && menu == null
        ? null
        : Builder(
            builder: (context) {
              final slot = ExplorerRow.slotOf(UiDensity.of(context));
              return Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: slot, height: slot, child: action),
                      SizedBox(width: slot, height: slot, child: menu),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

/// The one widget a hover rebuilds on the right: both children are handed in
/// and kept mounted, so a menu open under a hidden `⋮` still reports back.
class _TrailingSwap extends StatelessWidget {
  const _TrailingSwap({required this.meta, required this.actions});

  final Widget? meta;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final meta = this.meta;
    final actions = this.actions;
    final engaged =
        UiDensity.of(context).isTouch ||
        (RowInteractionScope.maybeOf(context)?.engaged ?? false);
    final showActions = actions != null && engaged;
    // The count keeps its size while hidden and the column never drops below a
    // button's height, so swapping one for the other moves nothing.
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: ExplorerRow.slotOf(UiDensity.of(context)),
      ),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          if (meta != null)
            Visibility(
              visible: !showActions,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: meta,
            ),
          if (actions != null)
            Visibility(
              visible: showActions,
              maintainState: true,
              maintainAnimation: true,
              child: actions,
            ),
        ],
      ),
    );
  }
}

/// A row's selection box. Drawn disabled, with [disabledTooltip] saying why,
/// for a row the selection cannot take — so the rule is visible, not silent.
class ExplorerRowTick extends StatelessWidget {
  const ExplorerRowTick({
    required this.value,
    required this.semanticLabel,
    required this.onChanged,
    this.disabledTooltip,
    super.key,
  });

  final bool value;
  final String semanticLabel;

  /// Null draws the box disabled.
  final VoidCallback? onChanged;
  final String? disabledTooltip;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final onChanged = this.onChanged;
    final box = Checkbox(
      value: value,
      semanticLabel: semanticLabel,
      visualDensity: density.isTouch
          ? VisualDensity.standard
          : VisualDensity.compact,
      materialTapTargetSize: density.isTouch
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
      onChanged: onChanged == null ? null : (_) => onChanged(),
    );
    final why = disabledTooltip;
    return onChanged != null || why == null
        ? box
        : Tooltip(message: why, child: box);
  }
}

/// A row's count or age: muted, tabular, one line.
class ExplorerRowMeta extends StatelessWidget {
  const ExplorerRowMeta(this.text, {this.tooltip, this.color, super.key});

  final String text;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = UiDensity.of(context)
        .muted(theme)
        ?.copyWith(
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    final label = Text(text, maxLines: 1, softWrap: false, style: style);
    return tooltip == null ? label : Tooltip(message: tooltip!, child: label);
  }
}

/// A row-level verb — "new session here", "open a terminal" — in the same slot
/// as the `⋮`.
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
    // Sized like [RowMenuButton], which wraps rather than constrains.
    return SizedBox(
      width: slot,
      height: slot,
      child: IconButton(
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
      ),
    );
  }
}
