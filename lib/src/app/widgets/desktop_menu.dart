import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// Compact, icon-led menu item sized for mouse-driven desktop menus.
class DesktopMenuItem<T> extends PopupMenuItem<T> {
  DesktopMenuItem({
    required super.value,
    required String label,
    required IconData icon,
    String? shortcut,
    bool destructive = false,
    super.enabled,
    super.key,
  }) : super(
         height: 32,
         padding: const EdgeInsets.symmetric(horizontal: 10),
         child: Builder(
           builder: (context) {
             final theme = Theme.of(context);
             final color = destructive
                 ? theme.colorScheme.error
                 : theme.colorScheme.onSurface;
             return Row(
               children: [
                 Icon(icon, size: Chrome.icon, color: color),
                 const SizedBox(width: 10),
                 Expanded(
                   child: Text(
                     label,
                     style: theme.textTheme.bodySmall?.copyWith(color: color),
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

class DesktopMenuDivider extends PopupMenuDivider {
  const DesktopMenuDivider({super.key}) : super(height: 7);
}

/// Right-click support, shared by every row that has a menu.
///
/// Lives beside [DesktopMenuItem] rather than in the Explorer because the Files
/// side panel needs the same gesture and the same menu chrome.
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    required this.menuItems,
    required this.onSelected,
    required this.child,
    super.key,
  });

  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onSelected;
  final Widget child;

  Future<void> _show(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: menuItems,
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
