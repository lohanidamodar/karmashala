import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

// The parts the Claude and Codex account sections share. Pure: each takes
// what it shows and the callbacks it fires, and the sections keep only their
// provider reads.

/// One installation's account card: which install, a refresh, the account in
/// force, and the capture and switch actions.
class AgentAccountCardFrame extends StatelessWidget {
  const AgentAccountCardFrame({
    required this.title,
    required this.busy,
    required this.onRefresh,
    required this.current,
    required this.onCapture,
    this.refreshTooltip = 'Re-read the current account',
    this.switchMenu,
    super.key,
  });

  /// The installation's environment, as the user knows it.
  final String title;

  /// A capture or switch is running: the refresh gives way to a spinner and
  /// the actions are disabled by their owner.
  final bool busy;
  final VoidCallback onRefresh;
  final String refreshTooltip;

  /// The account in force, or why there is none.
  final Widget current;

  /// Null disables Capture.
  final VoidCallback? onCapture;

  /// A [SwitchAccountMenu], when there is anything to switch to.
  final Widget? switchMenu;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(AppIcons.robot, size: Chrome.iconTitle),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    title,
                    style: MonoStyles.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (busy)
                  const InlineSpinner()
                else
                  IconButton(
                    tooltip: refreshTooltip,
                    visualDensity: VisualDensity.compact,
                    onPressed: onRefresh,
                    icon: const Icon(AppIcons.arrowsClockwise),
                  ),
              ],
            ),
            const SizedBox(height: Insets.sm),
            current,
            const SizedBox(height: Insets.sm),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                TextButton.icon(
                  onPressed: onCapture,
                  icon: const Icon(AppIcons.downloadSimple),
                  label: const Text('Capture current'),
                ),
                ?switchMenu,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Switch to" menu over saved accounts. The account in force is the
/// checked row, and cannot be re-picked — the caller says which that is.
class SwitchAccountMenu<T> extends StatelessWidget {
  const SwitchAccountMenu({
    required this.enabled,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    super.key,
  });

  final bool enabled;
  final String tooltip;
  final List<DesktopMenuItem<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      enabled: enabled,
      tooltip: tooltip,
      onSelected: onSelected,
      itemBuilder: (_) => items,
      child: const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.arrowsClockwise, size: Chrome.iconAction),
            SizedBox(width: Insets.xs),
            Text('Switch to'),
            Icon(AppIcons.caretDown, size: Chrome.iconAction),
          ],
        ),
      ),
    );
  }
}

/// The signed-in account: a checked title, then one line per detail.
class SignedInAccount extends StatelessWidget {
  const SignedInAccount({
    required this.title,
    this.details = const [],
    super.key,
  });

  final String title;

  /// Each its own line, in order; empty ones are the caller's to leave out.
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              AppIcons.checkCircle,
              size: Chrome.icon,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        for (final detail in details)
          Text(detail, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// A row in the saved-account pool: display and forget only, since switching
/// needs an install card's target environment.
class SavedAccountRow extends StatelessWidget {
  const SavedAccountRow({
    required this.title,
    required this.subtitle,
    required this.onForget,
    required this.forgetTooltip,
    super.key,
  });

  final String title;

  /// Empty draws no second line.
  final String subtitle;
  final VoidCallback onForget;
  final String forgetTooltip;

  /// The bullet: a mark, not a glyph — same call as the project card's badge.
  static const bulletSize = 8.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(AppIcons.circle, size: bulletSize),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: forgetTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onForget,
            icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
          ),
        ],
      ),
    );
  }
}

/// A token's expiry relative to [now]: "expires in 3h", "expired". [now] is
/// the app clock's reading, never the wall clock's, so a test can pin it.
String relativeExpiry(DateTime expiry, DateTime now) {
  final diff = expiry.difference(now);
  if (diff.isNegative) return 'expired';
  if (diff.inHours >= 24) return 'expires in ${diff.inDays}d';
  if (diff.inHours >= 1) return 'expires in ${diff.inHours}h';
  return 'expires in ${diff.inMinutes}m';
}
