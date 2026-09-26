import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';

/// Formats how long a command took, at whatever scale reads naturally.
String formatCommandDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  if (d.inSeconds < 60) {
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  final minutes = d.inMinutes;
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '${minutes}m ${seconds}s';
}

/// The commands OSC 133 saw in one pane; selecting one scrolls to its prompt.
/// Only reachable when the pane reported any, so there is no empty affordance.
class CommandHistorySheet extends StatelessWidget {
  const CommandHistorySheet({
    super.key,
    required this.blocks,
    required this.onSelect,
  });

  final List<CommandBlock> blocks;
  final ValueChanged<CommandBlock> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (blocks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Text(
          'No commands recorded yet.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      reverse: true,
      itemCount: blocks.length,
      itemBuilder: (context, index) {
        final block = blocks[blocks.length - 1 - index];
        return _CommandRow(block: block, onTap: () => onSelect(block));
      },
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.block, required this.onTap});

  final CommandBlock block;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final duration = block.duration;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.xs,
        ),
        child: Row(
          children: [
            // Never colour alone: a failure also carries its exit code as text.
            Icon(
              block.failed ? AppIcons.xCircle : AppIcons.check,
              size: Chrome.iconAction,
              color: block.failed ? scheme.error : scheme.onSurfaceVariant,
              semanticLabel: block.failed ? 'Failed' : 'Succeeded',
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                block.command ?? '(command not captured)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  color: block.command == null
                      ? scheme.onSurfaceVariant
                      : scheme.onSurface,
                ),
              ),
            ),
            if (block.failed) ...[
              const SizedBox(width: Insets.sm),
              Text(
                'exit ${block.exitCode}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.error,
                ),
              ),
            ],
            if (duration != null) ...[
              const SizedBox(width: Insets.sm),
              Text(
                formatCommandDuration(duration),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
