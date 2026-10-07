import 'package:flutter/material.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

/// One card of the editor: the Starts card, a step, Ready, Limits. [rail]
/// colours its left edge — the failure steps' amber.
class EditorNode extends StatelessWidget {
  const EditorNode({
    required this.title,
    required this.children,
    this.icon,
    this.hint,
    this.trailing = const [],
    this.rail,
    super.key,
  });

  final String title;
  final IconData? icon;
  final String? hint;
  final List<Widget> trailing;
  final List<Widget> children;
  final Color? rail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rail = this.rail;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: rail == null
                ? null
                : Border(
                    left: BorderSide(color: rail, width: Insets.xs),
                  ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (icon case final icon?) ...[
                      Icon(icon, size: Touch.icon, color: scheme.tertiary),
                      const SizedBox(width: Insets.sm),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.titleSmall),
                          if (hint case final hint?)
                            Text(
                              hint,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    ...trailing,
                  ],
                ),
                for (final child in children) ...[
                  const SizedBox(height: Insets.sm),
                  child,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The line joining two steps; amber, with "if it fails", before a failure
/// step.
class StepLink extends StatelessWidget {
  const StepLink({this.label, this.color, super.key});

  final String? label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = this.color ?? theme.colorScheme.outlineVariant;
    return SizedBox(
      height: Insets.xl,
      child: Row(
        children: [
          const SizedBox(width: Insets.xl),
          Container(width: Insets.xxs, color: color),
          if (label case final label?) ...[
            const SizedBox(width: Insets.sm),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ],
      ),
    );
  }
}

/// A line of muted text under a field.
class EditorNote extends StatelessWidget {
  const EditorNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Chips that insert a `{{name}}` at the end of [controller].
class VariableChips extends StatelessWidget {
  const VariableChips({
    required this.names,
    required this.controller,
    required this.onChanged,
    super.key,
  });

  final List<String> names;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Insets.xs,
    runSpacing: Insets.xs,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const EyebrowLabel('Insert'),
      for (final name in names)
        ActionChip(
          visualDensity: VisualDensity.compact,
          label: Text('{{$name}}'),
          onPressed: () {
            final text = '${controller.text}{{$name}}';
            controller.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
            onChanged();
          },
        ),
    ],
  );
}

/// The amber of a step that runs when something failed.
Color failureRail(BuildContext context) => SemanticColors.of(context).attention;
