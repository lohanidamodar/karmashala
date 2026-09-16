import 'package:flutter/material.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

/// The line at the top of an attach-to-something pane — the browser's and the
/// running Flutter app's: a status dot, what we are attached to, one action.
///
/// The text is what gives way; the action takes half the row at most and
/// scales down rather than wrapping, because the side panel is 240px.
class PaneStatusRow extends StatelessWidget {
  const PaneStatusRow({
    required this.color,
    required this.label,
    this.tooltip,
    this.action,
    super.key,
  });

  /// From [SemanticColors] or the colour scheme, never a raw hue.
  final Color color;

  /// The status in words; also what the dot announces.
  final String label;
  final String? tooltip;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            ExcludeSemantics(
              child: StatusDot(color: color, label: label),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: tooltip == null
                  ? text
                  : Tooltip(message: tooltip!, child: text),
            ),
            if (action case final action?) ...[
              const SizedBox(width: Insets.sm),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: action,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
