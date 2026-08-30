import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// A consistent frame for a shell pane: a compact header over a body.
///
/// Flat, not a card. The old frame gave every pane a rounded outline and a brass
/// accent rule, which read as three floating documents on a desk; a desktop
/// shell is one surface divided by hairlines, and the rounded corners cost real
/// pixels at the top of a pane that is mostly list. [focused] now shows in the
/// header label alone — enough to answer "which pane is the keyboard in", quiet
/// enough not to compete with the workbench.
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
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accent = focused ? scheme.onSurface : scheme.onSurfaceVariant;
    // A Material (not a plain DecoratedBox) so descendant ListTiles have a
    // valid background/ink ancestor to paint on.
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: Chrome.tabStrip,
            color: scheme.surfaceContainerLow,
            padding: const EdgeInsets.only(left: Insets.md, right: 2),
            child: Row(
              children: [
                Icon(icon, size: Chrome.iconSmall, color: accent),
                const SizedBox(width: Insets.sm),
                // Expanded rather than a Spacer: the title is the only thing
                // in this row that can give way, and at the Explorer's own
                // 200px minimum the actions alone are wider than the pane.
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(color: accent),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Centered empty-state placeholder used inside panes.
class PanePlaceholder extends StatelessWidget {
  const PanePlaceholder({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
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
