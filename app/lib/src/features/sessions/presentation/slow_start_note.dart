import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// How long a start may spin silently before [SlowStartNote] joins it.
const Duration kSlowStartAfter = Duration(seconds: 6);

/// Under the New Session dialog's spinner once a start has taken a while:
/// an agent run through npx is downloaded on its first start, which can
/// take minutes, and a bare spinner looked hung.
class SlowStartNote extends StatelessWidget {
  const SlowStartNote({super.key});

  static const String text =
      'Still starting. An agent run through npx is downloaded on its first '
      'start, which can take a few minutes; the server gives up on its own '
      'if it never answers.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.info, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
