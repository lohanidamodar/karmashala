import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// A consistent frame for a shell pane: a "ledger tab" header over a body.
///
/// All three panes share this chrome. [focused] lights the header's brass accent
/// so the active pane is obvious without a heavy border.
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
    final accent = focused ? scheme.tertiary : scheme.onSurfaceVariant;
    // A Material (not a plain DecoratedBox) so descendant ListTiles have a
    // valid background/ink ancestor to paint on.
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // "Ledger tab" header: a tracked label over a brass accent rule.
          Container(
            color: scheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.sm,
              Insets.sm,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 16, color: accent),
                    const SizedBox(width: Insets.sm),
                    Text(
                      title.toUpperCase(),
                      style: text.labelSmall?.copyWith(color: accent),
                    ),
                    const Spacer(),
                    ...actions,
                  ],
                ),
                const SizedBox(height: Insets.sm),
                // The accent rule: brass when focused, hairline otherwise.
                AnimatedContainer(
                  duration: Motion.fast,
                  height: focused ? 2 : 1,
                  color: focused ? scheme.tertiary : scheme.outlineVariant,
                ),
              ],
            ),
          ),
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
