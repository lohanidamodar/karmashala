import 'package:flutter/material.dart';

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
                 Icon(icon, size: 16, color: color),
                 const SizedBox(width: 10),
                 Expanded(
                   child: Text(
                     label,
                     style: theme.textTheme.bodySmall?.copyWith(color: color),
                   ),
                 ),
                 if (shortcut != null) ...[
                   const SizedBox(width: 24),
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
