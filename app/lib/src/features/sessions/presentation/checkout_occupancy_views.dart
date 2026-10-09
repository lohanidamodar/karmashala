import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/session.dart'
    show CheckoutOccupant, occupancySentence;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../environments/application/environment_values.dart'
    show EnvironmentPath;
import '../application/checkout_occupancy_providers.dart';

/// **Who else is writing where a session is about to work**, said before it
/// starts or attaches: "2 sessions are working in this checkout: …", and what
/// can be done about it. Draws nothing when nobody is. Advisory — it locks
/// nothing.
class CheckoutOccupancyWarning extends ConsumerWidget {
  const CheckoutOccupancyWarning({
    required this.directory,
    this.excluding,
    this.onUseWorktree,
    this.onStartAnyway,
    this.startLabel = 'Start anyway',
    this.onWait,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final EnvironmentPath directory;

  /// Around the warning, only when it draws.
  final EdgeInsetsGeometry padding;

  /// The session asking, which is not its own neighbour.
  final String? excluding;

  /// "Use a new worktree instead"; null where there is no worktree to offer.
  final VoidCallback? onUseWorktree;
  final VoidCallback? onStartAnyway;
  final String startLabel;
  final VoidCallback? onWait;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final occupants = ref.watch(
      checkoutOccupantsProvider((directory: directory, excluding: excluding)),
    );
    final sentence = occupancySentence(occupants);
    if (sentence == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    return Container(
      key: const ValueKey('checkout-occupancy-warning'),
      margin: padding,
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).attentionSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.warningCircle,
                size: Chrome.icon,
                color: semantic.attention,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  '$sentence One working tree, index and branch between '
                  'them: their edits and yours land in the same files.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              if (onWait != null)
                TextButton(
                  key: const ValueKey('checkout-occupancy-wait'),
                  onPressed: onWait,
                  child: const Text('Wait'),
                ),
              if (onStartAnyway != null)
                TextButton(
                  key: const ValueKey('checkout-occupancy-anyway'),
                  onPressed: onStartAnyway,
                  child: Text(startLabel),
                ),
              if (onUseWorktree != null)
                FilledButton.tonal(
                  key: const ValueKey('checkout-occupancy-worktree'),
                  onPressed: onUseWorktree,
                  child: const Text('Use a new worktree instead'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "shared with 1" beside a session's status, the tooltip naming who: other
/// live sessions that may write where this one works. Nothing when nobody.
class SharedCheckoutBadge extends ConsumerWidget {
  const SharedCheckoutBadge({required this.sessionId, super.key});

  final String sessionId;

  /// The tooltip: who, and what sharing means.
  static String tooltipFor(List<CheckoutOccupant> sharers) =>
      'Also writing in this checkout: '
      '${sharers.map((o) => o.phrase).join(', ')}. One working tree, index '
      'and branch between them — a new worktree keeps sessions apart.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sharers = ref.watch(sessionCheckoutSharersProvider(sessionId));
    if (sharers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colour = SemanticColors.of(context).attention;
    return Tooltip(
      message: tooltipFor(sharers),
      child: Row(
        key: ValueKey('shared-checkout:$sessionId'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.usersThree, size: Chrome.iconSmall, color: colour),
          const SizedBox(width: Insets.xs),
          Flexible(
            child: Text(
              'shared with ${sharers.length}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: colour),
            ),
          ),
        ],
      ),
    );
  }
}
