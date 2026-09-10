import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// The gutter every menu row shares, so a one-line row and a two-line row line
/// their labels up in the same menu.
const EdgeInsets _menuRowPadding = EdgeInsets.symmetric(horizontal: 10);
const double _menuGlyphGap = 10;

/// Compact, icon-led menu item sized for mouse-driven desktop menus.
class DesktopMenuItem<T> extends PopupMenuItem<T> {
  DesktopMenuItem({
    required super.value,
    required String label,
    required IconData icon,
    String? shortcut,
    bool destructive = false,
    bool selected = false,
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
             return Row(
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
             );
           },
         ),
       );
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
              Row(
                children: [
                  Flexible(
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
                  if (badge != null) ...[
                    const SizedBox(width: Insets.xs),
                    Text(
                      badge!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: badgeColor ?? scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.6,
      ),
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
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapDown: (details) => _show(context, details.globalPosition),
    child: child,
  );
}
