import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// Consistent title row for desktop dialogs, including a visible close affordance.
class DesktopDialogTitle extends StatelessWidget {
  const DesktopDialogTitle({
    required this.icon,
    required this.title,
    this.subtitle,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // 2px, and deliberately not an `Insets` step: optical alignment of the
          // glyph's cap height, which the 4-pt scale would drop below the title.
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            icon,
            size: Chrome.iconTitle,
            color: theme.colorScheme.tertiary,
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: Insets.xs),
                Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          icon: const Icon(AppIcons.x, size: Chrome.icon),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// An error said inside a dialog, above the form it belongs to.
class DesktopErrorBanner extends StatelessWidget {
  const DesktopErrorBanner(this.message, {this.onDismiss, super.key});
  final String message;

  /// Draws a close button when non-null — for an error that outlives the
  /// attempt that raised it, where the next edit does not clear it.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Icon(AppIcons.warningCircle, size: Chrome.icon, color: scheme.error),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              iconSize: Chrome.iconAction,
              color: scheme.onErrorContainer,
              icon: const Icon(AppIcons.x),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}
