import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_states.dart';

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
    // A machine paired by address is not "your desktop", and what to check
    // about it is different.
    final pairing = ref.watch(companionPairingProvider).asData?.value;
    final machine = pairing?.route != null;
    // The active desktop, when the person pinned its route.
    final pinned = ref
        .watch(companionConnectionsProvider)
        .asData
        ?.value
        .where((c) => c.active && c.route == null && !c.pin.isAuto)
        .firstOrNull;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final connecting = link == CompanionLinkState.connecting;
    final tone = connecting ? semantic.working : semantic.attention;
    // What the phone is doing and, once it knows, why it is still doing it —
    // "Connecting…" alone leaves nothing to act on.
    final headline = connecting
        ? machine
              ? 'Connecting to ${pairing?.hostName ?? 'the machine'}…'
              : 'Connecting to your desktop…'
        : 'Host unreachable';
    final detail =
        trouble ??
        (connecting
            ? null
            : machine
            ? 'Check that the machine is running and can be reached from here.'
            : 'Check that Karmashala is running on your desktop.');

    return Material(
      // The word carries the meaning and the tint only supports it, so the text
      // keeps full on-surface contrast.
      color: connecting ? semantic.workingSurface : semantic.attentionSurface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          density.padX,
          density.isTouch ? Insets.sm : Insets.xs,
          density.isTouch ? Insets.sm : Insets.xs,
          density.isTouch ? Insets.sm : Insets.xs,
        ),
        // Retry drops under the words once they would be squeezed to a column
        // a few letters wide, and the words stop at two lines each: the banner
        // sits above every screen and must not become the screen.
        child: StackWhenNarrow(
          breakpoint: _sideBySideWidth,
          spacing: Insets.xs,
          runSpacing: 0,
          stackedAlignment: CrossAxisAlignment.end,
          leading: Row(
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
                      maxLines: _maxLines,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (density.isTouch
                                  ? theme.textTheme.bodyMedium
                                  : theme.textTheme.bodySmall)
                              ?.copyWith(color: scheme.onSurface),
                    ),
                    // The gateway's own sentence: a relay that hung up saying
                    // nobody was there is not a broken network.
                    if (detail != null)
                      Text(
                        detail,
                        // A machine's trouble ends in its remedy — pair again
                        // by the other route — which two lines would cut off.
                        maxLines: machine ? _machineDetailLines : _maxLines,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // Offered while dialling too: a phone stuck on "connecting" needs a
          // way to start over as much as one that gave up.
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A pin is "only": the phone will not go around it by itself,
              // so the way around it is here, beside the reason.
              if (pinned != null)
                TextButton(
                  onPressed: () => _useAuto(context, ref, pinned),
                  child: const Text('Use Auto'),
                ),
              TextButton(
                onPressed: () => ref.read(companionGatewayProvider).reconnect(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _useAuto(
    BuildContext context,
    WidgetRef ref,
    CompanionConnection pinned,
  ) async {
    try {
      await ref
          .read(companionGatewayProvider)
          .setRoutePin(pinned.hostId, CompanionRoutePin.auto);
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(companionErrorText(error))),
      );
    }
  }

  /// The narrowest banner, at 1x text, that still gives the words a readable
  /// column beside Retry.
  static const _sideBySideWidth = 280.0;

  static const _maxLines = 2;
  static const _machineDetailLines = 4;
}
