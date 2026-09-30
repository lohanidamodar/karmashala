import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// The gutter every menu row shares, so a one-line row and a two-line row line
/// their labels up in the same menu.
const EdgeInsets _menuRowPadding = EdgeInsets.symmetric(horizontal: 10);
const double _menuGlyphGap = 10;

/// A popup row's body grown to [Touch.target] under a thumb: a popup that
/// opens on a phone (a chip's picker) keeps its rows but not their 32px.
class _TouchMenuRow extends StatelessWidget {
  const _TouchMenuRow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!UiDensity.of(context).isTouch) return child;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Touch.target),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        heightFactor: 1,
        child: child,
      ),
    );
  }
}

/// Compact, icon-led menu item sized for mouse-driven desktop menus.
class DesktopMenuItem<T> extends PopupMenuItem<T> {
  DesktopMenuItem({
    required super.value,
    required this.label,
    required this.icon,
    String? shortcut,
    this.destructive = false,
    this.selected = false,
    super.enabled,
    super.key,
  }) : super(
         height: Chrome.menuRow,
         padding: _menuRowPadding,
         child: Builder(
           builder: (context) {
             final theme = Theme.of(context);
             final color = destructive
                 ? theme.colorScheme.error
                 : selected
                 ? theme.colorScheme.primary
                 : theme.colorScheme.onSurface;
             return _TouchMenuRow(
               child: Row(
                 children: [
                   // In a pick-one menu the leading slot answers "which one is
                   // set", so the check takes the icon's place rather than
                   // crowding in beside it.
                   Icon(
                     selected ? AppIcons.check : icon,
                     size: Chrome.icon,
                     color: color,
                   ),
                   const SizedBox(width: _menuGlyphGap),
                   Expanded(
                     child: Text(
                       label,
                       maxLines: 1,
                       overflow: TextOverflow.ellipsis,
                       style: theme.textTheme.bodySmall?.copyWith(
                         color: color,
                         fontWeight: selected ? FontWeight.w600 : null,
                       ),
                     ),
                   ),
                   if (shortcut != null) ...[
                     const SizedBox(width: Insets.xl),
                     Text(
                       shortcut,
                       style: theme.textTheme.labelSmall?.copyWith(
                         fontWeight: FontWeight.w400,
                         letterSpacing: 0,
                       ),
                     ),
                   ],
                 ],
               ),
             );
           },
         ),
       );

  // Kept so a touch sheet can draw the same entry at 48dp (MenuSheetList).
  final String label;
  final IconData icon;
  final bool destructive;
  final bool selected;
}

/// A row in a show-or-hide list: a check slot, then the thing's own glyph and
/// name. Unlike [DesktopMenuItem]'s `selected`, several can be checked at once,
/// so a checked row is not emphasised — the check alone says it.
class DesktopMenuCheckItem<T> extends PopupMenuItem<T> {
  DesktopMenuCheckItem({
    required super.value,
    required this.label,
    required this.icon,
    required this.checked,
    super.enabled,
    super.key,
  }) : super(
         height: Chrome.menuRow,
         padding: _menuRowPadding,
         child: Builder(
           builder: (context) {
             final theme = Theme.of(context);
             final color = theme.colorScheme.onSurface;
             return Semantics(
               checked: checked,
               child: _TouchMenuRow(
                 child: Row(
                   children: [
                     SizedBox(
                       width: Chrome.icon,
                       child: checked
                           ? Icon(
                               AppIcons.check,
                               size: Chrome.icon,
                               color: color,
                             )
                           : null,
                     ),
                     const SizedBox(width: _menuGlyphGap),
                     Icon(
                       icon,
                       size: Chrome.icon,
                       color: theme.colorScheme.onSurfaceVariant,
                     ),
                     const SizedBox(width: _menuGlyphGap),
                     Expanded(
                       child: Text(
                         label,
                         maxLines: 1,
                         overflow: TextOverflow.ellipsis,
                         style: theme.textTheme.bodySmall?.copyWith(
                           color: color,
                         ),
                       ),
                     ),
                   ],
                 ),
               ),
             );
           },
         ),
       );

  final String label;
  final IconData icon;
  final bool checked;
}

/// The two-line sibling of [DesktopMenuItem], for pickers whose choices cannot
/// be named in one word, on the same gutter and type ramp as every other menu.
class DesktopMenuDetailItem<T> extends PopupMenuItem<T> {
  // A super parameter is not in scope in an initializer list, and `enabled`
  // has to reach the row below as well as `PopupMenuItem`.
  // ignore: use_super_parameters
  DesktopMenuDetailItem({
    required super.value,
    required String label,
    required String detail,
    IconData? icon,
    String? badge,
    Color? badgeColor,
    int? detailMaxLines,
    bool selected = false,
    bool enabled = true,
    super.key,
  }) : super(
         enabled: enabled,
         height: Chrome.menuRowTall,
         padding: _menuRowPadding,
         child: DesktopMenuDetailRow(
           label: label,
           detail: detail,
           icon: icon,
           badge: badge,
           badgeColor: badgeColor,
           detailMaxLines: detailMaxLines,
           selected: selected,
           enabled: enabled,
         ),
       );

  /// For the row whose detail is still being fetched when the menu opens —
  /// [child] builds a [DesktopMenuDetailRow] once it knows what to say.
  const DesktopMenuDetailItem.live({
    required super.value,
    required Widget super.child,
    super.enabled,
    super.key,
  }) : super(height: Chrome.menuRowTall, padding: _menuRowPadding);
}

/// The body of a [DesktopMenuDetailItem]; see [DesktopMenuDetailItem.live] for
/// why it is reachable on its own.
class DesktopMenuDetailRow extends StatelessWidget {
  const DesktopMenuDetailRow({
    required this.label,
    required this.detail,
    this.icon,
    this.badge,
    this.badgeColor,
    this.detailMaxLines,
    this.selected = false,
    this.enabled = true,
    super.key,
  });

  final String label;

  /// The second line: what picking this actually means.
  final String detail;

  /// The leading glyph, replaced by a check while [selected].
  final IconData? icon;

  /// A short qualifier after the label — "approximate", "not enforced".
  final String? badge;

  /// [badge]'s colour where the qualifier carries meaning; muted otherwise.
  final Color? badgeColor;

  /// Null lets [detail] wrap as far as it needs to.
  final int? detailMaxLines;

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = !enabled
        ? scheme.onSurfaceVariant
        : selected
        ? scheme.primary
        : scheme.onSurface;
    final glyph = selected ? AppIcons.check : icon;
    return _TouchMenuRow(child: _row(theme, scheme, color, glyph));
  }

  Widget _row(
    ThemeData theme,
    ColorScheme scheme,
    Color color,
    IconData? glyph,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The gutter is held even with no glyph, so a menu whose rows are checked one
        // at a time does not shuffle its labels sideways as the answer moves.
        SizedBox(
          width: Chrome.icon,
          child: glyph == null
              ? null
              : Icon(glyph, size: Chrome.icon, color: color),
        ),
        const SizedBox(width: _menuGlyphGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // A Wrap rather than a Row: the badge drops under the label when
              // both cannot fit, where two Flexibles would halve the label even
              // when there was room. A popup menu sizes by intrinsics, which a
              // Wrap answers and a LayoutBuilder cannot.
              Wrap(
                spacing: Insets.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
                  ),
                  if (badge != null)
                    Text(
                      badge!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: badgeColor ?? scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              Text(
                detail,
                maxLines: detailMaxLines,
                overflow: detailMaxLines == null
                    ? TextOverflow.clip
                    : TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class DesktopMenuDivider extends PopupMenuDivider {
  const DesktopMenuDivider({super.key}) : super(height: 7);
}

/// A section heading inside a menu: not selectable, and not a row. `enabled:
/// false` rather than a custom entry, so keyboard traversal skips it.
class DesktopMenuHeader<T> extends PopupMenuItem<T> {
  DesktopMenuHeader(String label, {super.key})
    : super(
        enabled: false,
        height: Chrome.menuRow,
        padding: _menuRowPadding,
        child: _HeaderLabel(label),
      );
}

class _HeaderLabel extends StatelessWidget {
  const _HeaderLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall
          ?.merge(Chrome.groupLabel)
          .copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

/// A menu's [items] as a list of 48dp rows, for a sheet under a thumb. A tap
/// pops the enclosing route with the item's value, as the popup would.
class MenuSheetList<T> extends StatelessWidget {
  const MenuSheetList({required this.items, super.key});

  final List<PopupMenuEntry<T>> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget tile({
      required PopupMenuItem<T> item,
      required String label,
      IconData? icon,
      String? detail,
      Color? color,
      bool checked = false,
      bool emphasised = false,
    }) {
      final tint = item.enabled ? color : scheme.onSurfaceVariant;
      return ListTile(
        enabled: item.enabled,
        minTileHeight: Touch.target,
        leading: checked
            ? Icon(AppIcons.check, size: Touch.icon, color: scheme.primary)
            : icon == null
            ? const SizedBox(width: Touch.icon)
            : Icon(icon, size: Touch.icon, color: tint),
        title: Text(
          label,
          style: TextStyle(
            color: tint,
            fontWeight: emphasised ? FontWeight.w600 : null,
          ),
        ),
        subtitle: detail == null ? null : Text(detail),
        onTap: () {
          item.onTap?.call();
          Navigator.of(context).pop<T>(item.value);
        },
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in items)
          switch (entry) {
            PopupMenuDivider() => const Divider(height: Insets.md),
            final DesktopMenuHeader<T> header => Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.md,
                Insets.lg,
                Insets.xs,
              ),
              child: header.child,
            ),
            final DesktopMenuItem<T> item => tile(
              item: item,
              label: item.label,
              icon: item.icon,
              color: item.destructive
                  ? scheme.error
                  : item.selected
                  ? scheme.primary
                  : null,
              checked: item.selected,
              emphasised: item.selected,
            ),
            final DesktopMenuCheckItem<T> item => tile(
              item: item,
              label: item.label,
              icon: item.icon,
              checked: item.checked,
            ),
            final PopupMenuItem<T> item
                when item.child is DesktopMenuDetailRow =>
              () {
                final row = item.child! as DesktopMenuDetailRow;
                return tile(
                  item: item,
                  label: row.label,
                  icon: row.icon,
                  detail: row.detail,
                  color: row.selected ? scheme.primary : null,
                  checked: row.selected,
                  emphasised: row.selected,
                );
              }(),
            // Anything else draws itself; a popup item pops its own route.
            _ => ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Touch.target),
              child: entry,
            ),
          },
      ],
    );
  }
}

/// Right-click, and only right-click. **Prefer `RowContextMenu`** on a row;
/// this is the pointer half, for a terminal body, a tab chip, a pane strip.
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    required this.itemBuilder,
    required this.onSelected,
    required this.child,
    super.key,
  });

  /// Called when the menu opens, and not before — as a `List` it was built on
  /// every build of every row.
  final List<PopupMenuEntry<String>> Function() itemBuilder;

  final ValueChanged<String> onSelected;
  final Widget child;

  Future<void> _show(BuildContext context, Offset position) async {
    final items = itemBuilder();
    if (items.isEmpty) return;
    final selected = await showDesktopMenuAt(context, position, items);
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapDown: (details) => _show(context, details.globalPosition),
    child: child,
  );
}

/// Opens [items] at [position], in the overlay's coordinates — a pointer's
/// global position under the app's root overlay. Null when nothing was picked
/// or there is no overlay to open in.
Future<T?> showDesktopMenuAt<T>(
  BuildContext context,
  Offset position,
  List<PopupMenuEntry<T>> items,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;
  return showMenu<T>(
    context: context,
    // A one-pixel anchor: the menu opens from the point, not over what was
    // under it.
    position: RelativeRect.fromRect(
      Rect.fromLTWH(position.dx, position.dy, 1, 1),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

/// Opens [items] under the widget [context] belongs to: from its left edge, or
/// its right when it sits in the overlay's right half. Null when nothing was
/// picked or that widget has not been laid out.
Future<T?> showDesktopMenuUnder<T>(
  BuildContext context,
  List<PopupMenuEntry<T>> items,
) async {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) return null;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + box.size.height,
      overlay.size.width - origin.dx - box.size.width,
      0,
    ),
    items: items,
  );
}
