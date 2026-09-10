import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';

/// The strip that says the host cannot be reached, drawn above every tab and
/// never a toast that scrolls away.
class LinkBanner extends ConsumerWidget {
  const LinkBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Say nothing until the stream answers: "unreachable" before anything was
    // tried is false.
    final link = ref.watch(companionLinkProvider).asData?.value;
    if (link == null || link == CompanionLinkState.connected) {
      return const SizedBox.shrink();
    }

    // Watched, not read: the reason arrives with no link-state change behind
    // it, so a `ref.read` would wait for somebody else's rebuild.
    final trouble = ref.watch(companionLinkTroubleProvider).asData?.value;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final connecting = link == CompanionLinkState.connecting;
    final tone = connecting ? semantic.working : semantic.attention;
    // What the phone is doing and, once it knows, why it is still doing it —
    // "Connecting…" alone leaves nothing to act on.
    final headline = connecting
        ? 'Connecting to your desktop…'
        : 'Host unreachable';
    final detail =
        trouble ??
        (connecting
            ? null
            : 'Check that Karmashala is running on your desktop.');

    return Material(
      // The word carries the meaning and the tint only supports it, so the text
      // keeps full on-surface contrast.
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
                  // The gateway's own sentence: a relay that hung up saying
                  // nobody was there is not a broken network.
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
            // Offered while dialling too: a phone stuck on "connecting" needs a
            // way to start over as much as one that gave up.
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
