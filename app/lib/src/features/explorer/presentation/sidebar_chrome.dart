import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

/// **The sidebar's measurements** (UI overhaul spec §3–4, board A2): one place
/// for the header, the group label, the row and the list's own padding, so the
/// Sessions, Projects, Terminals and Inbox areas and the Devices dock cannot
/// drift apart. Regions and groups are told apart by tone and spacing only —
/// nothing here draws a band or a rule between sections.
class Sidebar {
  const Sidebar._();

  /// An area's header: its name, then its verbs.
  static const headerHeight = 44.0;

  /// 16 before the name, 8 after the last button.
  static const headerPadding = EdgeInsets.only(
    left: Insets.lg,
    right: Insets.sm,
  );

  /// Between the name and each header button.
  static const headerGap = 6.0;

  /// A header button: small and square-ish, so three fit beside a long name.
  static const headerButton = Size(28, 26);

  /// A group label's line (`.grp`).
  static const groupHeight = 24.0;

  /// A row's line (`.row`): one line, 28 under a pointer. Handed to every
  /// sidebar [ExplorerRow] as its `minHeight` — a floor, padding included, so
  /// a row still grows with its text.
  static const rowHeight = 28.0;

  /// Above a group that follows another: the space *is* the separator.
  static const groupGap = Insets.sm;

  /// A group label's words from its fill's left edge — the mockup's `0 10px`.
  static const labelPadX = 10.0;

  /// A list's own padding. Every sidebar row insets its fill another
  /// [ExplorerRow.inset] (4), so a row's fill lands 6 from the sidebar's edge
  /// and 8 from its top — the mockup's `padding: 8px 6px`.
  static const listPadding = EdgeInsets.fromLTRB(
    Insets.xxs,
    Insets.sm,
    Insets.xxs,
    Insets.sm,
  );

  /// Where a row's fill lands from the sidebar's side: [listPadding] and
  /// [ExplorerRow.inset]. The search field and the filter row above a list
  /// stand on it too, so the three are one column.
  static const fillEdge = 6.0;

  /// Between the rows of a list: one hairline, as [ExplorerRow] keeps.
  static const rowGap = Insets.hair;

  /// The label's hand: 11/600, tracked .04em, written uppercase by the caller.
  static const TextStyle groupLabelStyle = TextStyle(
    fontSize: TypeSizes.caption,
    fontWeight: FontWeight.w600,
    letterSpacing: 11 * 0.04,
  );

  /// Where a group label's count ends, from its fill's right edge: the same
  /// column an [ExplorerRow]'s count ends in, scrollbar lane and all, so a
  /// header's number and its rows' numbers share one edge.
  static double labelTrailOf(UiDensity density) =>
      density.padX + ExplorerRow.scrollbarGutter;
}

/// **An area's header** (spec §4): the name at 13/600, then the area's verbs as
/// small quiet buttons, then **+**. No rule under it — the list below starts on
/// the same tone.
class SidebarAreaHeader extends StatelessWidget {
  const SidebarAreaHeader({
    required this.title,
    this.meta,
    this.actions = const [],
    this.newLabel,
    this.onNew,
    super.key,
  });

  final String title;

  /// A muted word after the name — `3 new`.
  final String? meta;

  /// The area's own verbs, drawn before the +.
  final List<Widget> actions;

  /// The + button's tooltip; with [onNew], the + is drawn.
  final String? newLabel;
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = this.meta;
    final onNew = this.onNew;
    final buttons = [
      ...actions,
      if (onNew != null)
        IconButton(
          tooltip: newLabel,
          icon: const Icon(AppIcons.plus),
          onPressed: onNew,
        ),
    ];
    return SizedBox(
      height: Sidebar.headerHeight,
      child: Padding(
        padding: Sidebar.headerPadding,
        child: SidebarHeaderButtons(
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: TypeSizes.body,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (meta != null) ...[
                      const SizedBox(width: Insets.sm),
                      Text(
                        meta,
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: TypeSizes.label,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              for (final button in buttons) ...[
                const SizedBox(width: Sidebar.headerGap),
                button,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Sizes every [IconButton] under it as a sidebar header button (`.tab`):
/// 28×26, radius 6, muted glyph; hovered on the ink wash, and — while it is a
/// toggle that is on — filled with the selected tone and drawn in full ink.
/// Material's 48px squares would crowd three into a 264px header.
class SidebarHeaderButtons extends StatelessWidget {
  const SidebarHeaderButtons({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tones = SurfaceTones.of(context);
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Sidebar.headerButton),
          maximumSize: const WidgetStatePropertyAll(Sidebar.headerButton),
          fixedSize: const WidgetStatePropertyAll(Sidebar.headerButton),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          iconSize: const WidgetStatePropertyAll(Chrome.icon),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
            ),
          ),
          // The hover is a tone in the fill (`.tab:hover`), not an overlay, so
          // a toggle that is on keeps its selected tone under the pointer.
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? tones.selected
                : states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                ? tones.hover
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? scheme.outline
                : states.contains(WidgetState.selected) ||
                      states.contains(WidgetState.hovered)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
          // Transparent, not null, while hovered or focused: a null falls
          // through to Material's own wash, which would stack on the tone.
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? StateLayers.pressed(scheme)
                : states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                ? Colors.transparent
                : null,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// **A group's label over its rows** (`.grp`): 24px, 11/600 uppercase, tracked,
/// in the dim ink — or the group's own state colour — with its count at the
/// right. A context wears its colour dot before the name. No band and no rule:
/// the [spaceAbove] gap is what separates one group from the one before it.
///
/// A group that folds is a real row: a keyboard stop the arrow keys reach
/// (through [ExplorerRowFocus]), a right-click menu, and a caret that shows
/// while it is folded or under the pointer.
class SidebarGroupLabel extends StatelessWidget {
  const SidebarGroupLabel({
    required this.label,
    this.count,
    this.countTooltip,
    this.hue,
    this.leading,
    this.color,
    this.detail,
    this.expanded,
    this.onTap,
    this.spaceAbove = false,
    this.action,
    this.menuLabel,
    this.menuItemsBuilder,
    this.onMenu,
    this.tooltip,
    super.key,
  });

  final String label;

  /// The count at the right. Never a fabricated zero: null where nothing has
  /// been measured (§19).
  final String? count;

  /// What [count] counts, in words.
  final String? countTooltip;

  /// A context's colour, as a dot before the name.
  final ContextHue? hue;

  /// A glyph before the name, where the group has one — the Devices dock's.
  final Widget? leading;

  /// The label's ink, for a group whose name is its state — amber *Needs
  /// you*, accent *Working*. Dim otherwise.
  final Color? color;

  /// A muted clause after the name — "read 2 minutes ago".
  final String? detail;

  /// Whether the rows under it are drawn, for a group that folds; null for one
  /// that does not.
  final bool? expanded;

  final VoidCallback? onTap;

  /// [Sidebar.groupGap] above: between groups, never before the first.
  final bool spaceAbove;

  /// The group's verb, in place of the count while the row is engaged.
  final Widget? action;

  final String? menuLabel;
  final RowMenuItemBuilder? menuItemsBuilder;
  final ValueChanged<String>? onMenu;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final menuItemsBuilder = this.menuItemsBuilder;
    final onMenu = this.onMenu;
    final interactive =
        onTap != null || (menuItemsBuilder != null && onMenu != null);
    Widget row = interactive
        ? RevealOnFocus(
            child: RowContextMenu(
              menuLabel: menuLabel ?? ExplorerRowKind.group.menuLabel,
              itemBuilder: menuItemsBuilder != null && onMenu != null
                  ? menuItemsBuilder
                  : null,
              onSelected: onMenu ?? (_) {},
              builder: _body,
            ),
          )
        : Builder(builder: _body);
    if (expanded != null) row = Semantics(expanded: expanded, child: row);
    if (tooltip case final message?) {
      row = Tooltip(message: message, child: row);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ExplorerRow.inset,
        spaceAbove ? Sidebar.groupGap : 0,
        ExplorerRow.inset,
        ExplorerRow.gapOf(density),
      ),
      child: row,
    );
  }

  /// Built under the row's [RowInteractionScope], so a hover repaints this and
  /// nothing above it.
  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final interaction = RowInteractionScope.maybeOf(context);
    final engaged = interaction?.engaged ?? false;
    final focused = interaction?.focused ?? false;
    final hovered = onTap != null && (interaction?.hovered ?? false);
    final ink = color ?? scheme.outline;
    final style = theme.textTheme.labelSmall
        ?.merge(Sidebar.groupLabelStyle)
        .copyWith(color: ink);
    final countStyle = style?.copyWith(
      color: scheme.outline,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final hue = this.hue;
    final leading = this.leading;
    final detail = this.detail;
    final expanded = this.expanded;
    final count = this.count;
    final action = this.action;
    final menuItemsBuilder = this.menuItemsBuilder;
    final onMenu = this.onMenu;
    final menu = menuItemsBuilder == null || onMenu == null
        ? null
        : RowMenuButton(
            tooltip: menuLabel ?? ExplorerRowKind.group.menuLabel,
            itemBuilder: menuItemsBuilder,
            onSelected: onMenu,
          );
    final countText = count == null
        ? null
        : Text(count, maxLines: 1, softWrap: false, style: countStyle);
    final countTooltip = this.countTooltip;
    final Widget? meta = countText == null || countTooltip == null
        ? countText
        : Tooltip(message: countTooltip, child: countText);
    final Widget? trailing = action == null && menu == null
        ? meta
        : SizedBox(
            width: ExplorerRow.trailingWidthOf(context),
            child: ExplorerRowTrailing(meta: meta, action: action, menu: menu),
          );
    // The caret says a group folds; drawn while it is folded, which the rows'
    // absence alone would not say, or while the pointer or keyboard is on it.
    final showCaret = expanded == false || (expanded != null && engaged);

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Sidebar.groupHeight),
      child: Padding(
        padding: EdgeInsets.only(
          left: Sidebar.labelPadX,
          right: Sidebar.labelTrailOf(density),
        ),
        child: Row(
          children: [
            if (hue != null) ...[
              ContextHueDot(
                hue: hue,
                size: Chrome.dot,
                label: '${hue.label} context',
              ),
              const SizedBox(width: Sidebar.headerGap),
            ],
            if (leading != null) ...[
              IconTheme.merge(
                data: IconThemeData(size: Chrome.iconSmall, color: ink),
                child: leading,
              ),
              const SizedBox(width: Sidebar.headerGap),
            ],
            // One Expanded owns all the free space, so the count is pushed flush
            // right (the mockup's `margin-left: auto`). A loose `Flexible`
            // label beside a `Spacer` split that space by flex — each got
            // half, the label used only its text's width, and the unused half
            // was never handed to the Spacer, so the count landed mid-row.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  if (showCaret) ...[
                    const SizedBox(width: Insets.xs),
                    Icon(
                      (expanded ?? false)
                          ? AppIcons.caretDown
                          : AppIcons.caretRight,
                      size: density.iconSmall,
                      color: scheme.outline,
                    ),
                  ],
                  if (detail != null) ...[
                    const SizedBox(width: Sidebar.headerGap),
                    Flexible(
                      child: Text(
                        detail,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: density
                            .muted(theme)
                            ?.copyWith(color: scheme.outline),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Sidebar.headerGap),
              trailing,
            ],
          ],
        ),
      ),
    );
    if (onTap == null && menu == null) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        // The ladder's hover tone, as a row's: a label and the rows under it
        // light alike.
        color: hovered ? SurfaceTones.of(context).hover : null,
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
        border: focused
            ? Border.all(
                color: StateLayers.focusRing(scheme),
                width: StateLayers.focusRingWidth,
              )
            : null,
      ),
      child: InkWell(
        onTap: onTap,
        focusNode: ExplorerRowFocus.maybeOf(context),
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
        // The fill above is the hover; the ink's own would stack on it.
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: content,
      ),
    );
  }
}

/// **A filter chip** (`.pill`): 24px, radius 6, 12px, on the floating hairline;
/// the one in force is filled with the selected tone and drawn in full ink.
/// The History tab's three records are switched with these.
class SidebarPill extends StatelessWidget {
  const SidebarPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.leading,
    this.tooltip,
    this.semanticLabel,
    this.maxLabelWidth,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// A dot or glyph before the label.
  final Widget? leading;
  final String? tooltip;

  /// What a screen reader hears in the label's place.
  final String? semanticLabel;

  /// The most the label may take before it is ellipsised.
  final double? maxLabelWidth;

  /// Between the leading mark and the label (the mockup's `gap: 5px`).
  static const leadGap = 5.0;

  /// Each side of the label.
  static const padX = 9.0;

  static const height = 24.0;

  static const _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final leading = this.leading;
    final maxLabelWidth = this.maxLabelWidth;
    Widget text = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        fontSize: TypeSizes.label,
        letterSpacing: 0,
        fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
        color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
      ),
    );
    if (maxLabelWidth != null) {
      text = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabelWidth),
        child: text,
      );
    }
    Widget body = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: leadGap)],
        Flexible(child: text),
      ],
    );
    if (semanticLabel != null) body = ExcludeSemantics(child: body);
    Widget pill = Material(
      color: selected ? tones.selected : Colors.transparent,
      shape: _shape.copyWith(side: BorderSide(color: tones.floatingLine)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: _shape,
        // `.pill:hover`. A pill in force keeps its selected tone instead:
        // the ink's hover colour is painted over the Material's own fill.
        hoverColor: selected ? Colors.transparent : tones.hover,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: height),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: padX),
            child: body,
          ),
        ),
      ),
    );
    if (tooltip case final message?) {
      pill = Tooltip(message: message, child: pill);
    }
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      child: pill,
    );
  }
}

/// **A filter as a quiet tab**: the Explorer's group filter and its machine
/// menu. No outline — muted words at rest, the hover tone under the pointer,
/// and the one in force filled with the selected tone in full ink, the way
/// the app's tabs and the settings nav say "this one". Keyboard focus is the
/// app's 1px ring, as on every sidebar row.
class SidebarFilterTab extends StatefulWidget {
  const SidebarFilterTab({
    required this.selected,
    required this.onTap,
    this.label,
    this.leading,
    this.trailing,
    this.tooltip,
    this.semanticLabel,
    this.maxLabelWidth,
    this.padding = padX,
    super.key,
  });

  /// Null for a tab that is its [leading] glyph alone.
  final String? label;
  final bool selected;
  final VoidCallback onTap;

  /// A dot or glyph before the label.
  final Widget? leading;

  /// A caret after it, for a tab that opens a menu.
  final Widget? trailing;
  final String? tooltip;

  /// What a screen reader hears in the label's place.
  final String? semanticLabel;

  /// The most the label may take before it is ellipsised.
  final double? maxLabelWidth;

  /// Each side of the content.
  final double padding;

  /// A pill's height: the row is the search field's companion, not a strip.
  static const height = 24.0;

  /// Each side of the label.
  static const padX = Insets.sm;

  /// Between the leading mark and the label, and the label and the caret.
  static const gap = Insets.xs;

  static const _radius = BorderRadius.all(Radius.circular(Radii.sm));

  /// The label's hand, at the weight of the tab in force — what a row of tabs
  /// is measured in, so a click never changes which of them fit.
  static TextStyle? styleOf(ThemeData theme) => theme.textTheme.labelSmall
      ?.merge(Chrome.tabLabel)
      .copyWith(letterSpacing: 0, fontWeight: FontWeight.w500);

  /// What a tab whose label measures [text] takes of a row, with a [lead]
  /// mark before it and a [trail] after. A hairline is kept back: what is
  /// drawn is not what was measured to the last fraction.
  static double widthFor(double text, {double lead = 0, double trail = 0}) =>
      text +
      (lead > 0 ? lead + gap : 0) +
      (trail > 0 ? trail + gap : 0) +
      padX * 2 +
      Insets.hair;

  @override
  State<SidebarFilterTab> createState() => _SidebarFilterTabState();
}

class _SidebarFilterTabState extends State<SidebarFilterTab> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final selected = widget.selected;
    final ink = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    final label = widget.label;
    final leading = widget.leading;
    final trailing = widget.trailing;
    final maxLabelWidth = widget.maxLabelWidth;
    Widget? text;
    if (label != null) {
      text = Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: SidebarFilterTab.styleOf(theme)?.copyWith(
          color: ink,
          fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
        ),
      );
      if (maxLabelWidth != null) {
        text = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxLabelWidth),
          child: text,
        );
      }
    }
    Widget glyph(Widget child) => IconTheme.merge(
      data: IconThemeData(size: Chrome.iconSmall, color: ink),
      child: child,
    );
    Widget body = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leading != null) glyph(leading),
        if (leading != null && text != null)
          const SizedBox(width: SidebarFilterTab.gap),
        if (text != null) Flexible(child: text),
        if (trailing != null) ...[
          const SizedBox(width: SidebarFilterTab.gap),
          glyph(trailing),
        ],
      ],
    );
    if (widget.semanticLabel != null) body = ExcludeSemantics(child: body);
    Widget tab = DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? tones.selected
            : _hovered
            ? tones.hover
            : null,
        borderRadius: SidebarFilterTab._radius,
        border: _focused
            ? Border.all(
                color: StateLayers.focusRing(scheme),
                width: StateLayers.focusRingWidth,
              )
            : null,
      ),
      child: InkWell(
        onTap: widget.onTap,
        onHover: (hovered) => setState(() => _hovered = hovered),
        onFocusChange: (focused) => setState(() => _focused = focused),
        borderRadius: SidebarFilterTab._radius,
        // The fill above is the hover and the ring the focus; the ink's own
        // would stack on them.
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: SidebarFilterTab.height),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.padding),
            child: body,
          ),
        ),
      ),
    );
    if (widget.tooltip case final message?) {
      tab = Tooltip(message: message, child: tab);
    }
    return Semantics(
      button: true,
      selected: selected,
      label: widget.semanticLabel,
      child: tab,
    );
  }
}
