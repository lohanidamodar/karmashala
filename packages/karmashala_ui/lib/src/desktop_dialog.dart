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

/// A dialog's `content`: [width] wide when the window has room and narrower
/// when it does not, scrolling when taller than the window, with its own
/// [FocusTraversalGroup] so Tab finishes the body before reaching the actions.
///
/// Use it for a dialog with a fixed design width — pass a [DialogWidth]. Use
/// `AlertDialog(scrollable: true)` instead only when the title should scroll
/// away with the body; never both, or there are two scroll views.
class BoundedDialogContent extends StatelessWidget {
  const BoundedDialogContent({
    required this.width,
    required this.child,
    super.key,
  });

  /// The design width, clamped to what the dialog is given.
  final double width;

  /// The body. Must not scroll vertically itself.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      // A SizedBox rather than a LayoutBuilder: AlertDialog sizes its body by
      // intrinsics, which a LayoutBuilder cannot answer.
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(primary: false, child: child),
      ),
    );
  }
}

/// The confirm button of an action that cannot be taken back: a filled button
/// in the error colours. Pair it with a plain `TextButton` to cancel.
class DestructiveButton extends StatelessWidget {
  const DestructiveButton({
    required this.onPressed,
    required this.child,
    this.icon,
    this.autofocus = false,
    super.key,
  });

  /// Null disables it, in the theme's disabled colours rather than red.
  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      backgroundColor: scheme.error,
      foregroundColor: scheme.onError,
    );
    final icon = this.icon;
    return icon == null
        ? FilledButton(
            onPressed: onPressed,
            autofocus: autofocus,
            style: style,
            child: child,
          )
        : FilledButton.icon(
            onPressed: onPressed,
            autofocus: autofocus,
            style: style,
            icon: icon,
            label: child,
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
