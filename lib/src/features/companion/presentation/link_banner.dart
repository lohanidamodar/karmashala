import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';

/// The strip that says the host cannot be reached, drawn above every tab.
///
/// A companion with no host is the first thing a user sees, so the state is
/// said plainly and stays visible — never a toast that scrolls away. It is
/// tinted with the semantic colour for what it is (amber for "you are cut
/// off", the working blue while dialling) rather than painted in chrome grey,
/// because it is the one thing on screen that is not ordinary.
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

    // Watched, not read: the reason usually arrives with no link-state change
    // behind it, and a `ref.read` here only ever refreshes on somebody else's
    // rebuild — which on the first pass after launch never comes.
    final trouble = ref.watch(companionLinkTroubleProvider).asData?.value;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final connecting = link == CompanionLinkState.connecting;
    final tone = connecting ? semantic.working : semantic.attention;
    // What the phone is doing, and — when it has learned anything — WHY it is
    // still doing it. "Connecting…" on its own is the state the owner was
    // stuck in with nothing to act on: no reason, and no way to try again.
    final headline = connecting
        ? 'Connecting to your desktop…'
        : 'Host unreachable';
    final detail =
        trouble ??
        (connecting
            ? null
            : 'Check that Chitragupta is running on your desktop.');

    return Material(
      // The word carries the meaning and the tint only supports it, so the
      // text stays at full on-surface contrast instead of borrowing the tone.
      color: tone.withValues(alpha: 0.12),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          density.padX,
          density.isTouch ? Insets.sm : Insets.xs,
          density.isTouch ? Insets.sm : Insets.xs,
          density.isTouch ? Insets.sm : Insets.xs,
        ),
        child: Row(
          children: [
            Icon(
              connecting ? AppIcons.arrowsClockwise : AppIcons.linkBreak,
              size: density.icon,
              color: tone,
            ),
            SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    headline,
                    style: (density.isTouch
                        ? theme.textTheme.bodyMedium
                        : theme.textTheme.bodySmall)?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  // The gateway's own sentence when it knows something more
                  // exact — a relay that hung up saying nobody was there is
                  // not a broken network, and a relay this phone could not
                  // reach is not a claim about the desktop at all.
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            // Always offered, dialling included: a phone that has been
            // "connecting" for a minute needs a way to start over as much as
            // one that has given up.
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
