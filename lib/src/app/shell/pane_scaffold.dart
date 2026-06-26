import 'package:flutter/material.dart';

/// A consistent frame for a shell pane: a titled header bar over a body.
///
/// Used by the placeholder feature panels in Loop 0 so all three panes share the
/// same chrome. [focused] highlights the pane whose pane is currently focused.
class PaneScaffold extends StatelessWidget {
  const PaneScaffold({
    required this.title,
    required this.icon,
    required this.body,
    this.actions = const [],
    this.focused = false,
    super.key,
  });

  final String title;
  final IconData icon;
  final Widget body;
  final List<Widget> actions;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = focused
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    // A Material (not a plain DecoratedBox) so descendant ListTiles have a
    // valid background/ink ancestor to paint on.
    return Material(
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor, width: focused ? 1.5 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                ...actions,
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Centered empty-state placeholder used inside panes during Loop 0.
class PanePlaceholder extends StatelessWidget {
  const PanePlaceholder({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
