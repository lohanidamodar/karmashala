import 'package:agent_cli/read.dart' show kRedactedThinking;
import 'package:flutter/material.dart';

import '../app_icons.dart';
import '../design_tokens.dart';

/// An interactive accordion for agent reasoning / chain-of-thought. Drawn under
/// a transcript's selection area: the reasoning selects, the header does not.
class ThinkingAccordion extends StatefulWidget {
  const ThinkingAccordion({required this.thinking, super.key});
  final String thinking;

  @override
  State<ThinkingAccordion> createState() => _ThinkingAccordionState();
}

class _ThinkingAccordionState extends State<ThinkingAccordion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    // Encrypted reasoning: a marker that it happened, with nothing to open.
    if (widget.thinking.trim() == kRedactedThinking) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          children: [
            Icon(
              AppIcons.chatCircleDots,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            Flexible(
              child: Text(
                kRedactedThinking,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final lines = widget.thinking.split('\n').length;
    final summary = lines <= 1 ? 'Thought' : 'Thought for $lines lines';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Insets.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(Radii.sm),
              child: ConstrainedBox(
                // A 24px header is a pointer's target; a thumb needs the floor.
                constraints: BoxConstraints(minHeight: density.minRow),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm,
                    vertical: Insets.xs,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        AppIcons.chatCircleDots,
                        size: Chrome.iconAction,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Insets.xs),
                      // Expanded, not a Text beside a Spacer: the summary is the
                      // one thing in this row that can give way.
                      Expanded(
                        child: Text(
                          summary,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded ? AppIcons.caretDown : AppIcons.caretRight,
                        size: Chrome.iconAction,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: Text(
                widget.thinking,
                style: MonoStyles.small.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
