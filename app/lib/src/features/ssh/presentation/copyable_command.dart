import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// The line that fixes it, offered to copy rather than to retype.
class CopyableCommand extends StatelessWidget {
  const CopyableCommand({required this.command, super.key});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.xs,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(command, style: MonoStyles.small),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Copy command',
            icon: const Icon(AppIcons.copySimple, size: Chrome.icon),
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ],
      ),
    );
  }
}
