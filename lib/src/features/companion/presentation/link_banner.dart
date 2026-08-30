import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';

/// The strip that says the host cannot be reached, drawn above every tab.
///
/// A companion with no host is the first thing a user sees, so the state is
/// said plainly and stays visible — never a toast that scrolls away.
class LinkBanner extends ConsumerWidget {
  const LinkBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // While the stream has not answered yet, say nothing: a banner claiming
    // the host is unreachable before anything was tried would be a false one.
    final link = ref.watch(companionLinkProvider).asData?.value;
    if (link == null || link == CompanionLinkState.connected) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connecting = link == CompanionLinkState.connecting;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.md,
          Insets.xs,
          Insets.xs,
          Insets.xs,
        ),
        child: Row(
          children: [
            Icon(
              connecting ? AppIcons.arrowsClockwise : AppIcons.linkBreak,
              size: Chrome.icon,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                connecting
                    ? 'Connecting to your desktop…'
                    : 'Host unreachable — check that Chitragupta is running '
                          'on your desktop.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (!connecting)
              TextButton(
                onPressed: () => ref.read(companionGatewayProvider).reconnect(),
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }
}
