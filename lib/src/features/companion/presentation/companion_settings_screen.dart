import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';

/// The companion's settings: who this phone is paired with, whether the link
/// is up, what was granted, and the way out.
class CompanionSettingsScreen extends ConsumerWidget {
  const CompanionSettingsScreen({super.key});

  Future<void> _unpair(BuildContext context, WidgetRef ref) async {
    final gateway = ref.read(companionGatewayProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unpair from this desktop?'),
        content: const Text(
          'This phone forgets the pairing and stops receiving sessions. To '
          "also revoke this phone's key, use the desktop's Remote access "
          'settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await gateway.unpair();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pairing = ref.watch(companionPairingProvider).asData?.value;
    final link =
        ref.watch(companionLinkProvider).asData?.value ??
        CompanionLinkState.disconnected;
    final path = ref.watch(companionLinkPathProvider).asData?.value;

    if (pairing == null) {
      // The shell shows the pairing flow before the tabs exist, so this is
      // only reachable in the moment after an unpair.
      return Center(
        child: Text(
          'Not paired.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final (linkIcon, linkLabel, linkColour) = switch (link) {
      // Which path carries the link matters at home: the direct socket skips
      // the relay entirely, and the user deserves to see that it did.
      CompanionLinkState.connected => (
        AppIcons.linkSimple,
        path == null ? 'Connected' : 'Connected · ${path.label}',
        SemanticColors.of(context).idle,
      ),
      CompanionLinkState.connecting => (
        AppIcons.arrowsClockwise,
        'Connecting…',
        SemanticColors.of(context).working,
      ),
      CompanionLinkState.disconnected => (
        AppIcons.linkBreak,
        'Host unreachable',
        SemanticColors.of(context).failure,
      ),
    };

    return ListView(
      padding: const EdgeInsets.all(Insets.md),
      children: [
        Text(
          'PAIRED DESKTOP',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.xs),
        Container(
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    AppIcons.deviceMobile,
                    size: Chrome.icon,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      pairing.hostName ?? 'Desktop',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(linkIcon, size: Chrome.iconSmall, color: linkColour),
                  const SizedBox(width: 4),
                  Text(
                    linkLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: linkColour,
                    ),
                  ),
                ],
              ),
              if (pairing.hostId != null) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  'Host id: ${pairing.hostId!.value}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFamily: kMonoFamily,
                  ),
                ),
              ],
              const SizedBox(height: Insets.sm),
              Text(
                'This phone may: '
                '${pairing.capabilities.granted.map((c) => c.wire.replaceAll('_', ' ')).join(', ')}.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (link == CompanionLinkState.disconnected) ...[
                const SizedBox(height: Insets.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(companionGatewayProvider).reconnect(),
                    icon: const Icon(AppIcons.arrowsClockwise, size: 14),
                    label: const Text('Try to reconnect'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Insets.lg),
        OutlinedButton.icon(
          onPressed: () => _unpair(context, ref),
          icon: const Icon(AppIcons.linkBreak, size: 14),
          label: const Text('Unpair from this desktop'),
        ),
        const SizedBox(height: Insets.lg),
        Text(
          'Chitragupta companion — a remote view of the sessions your '
          'desktop holds. The desktop is the source of truth; revoking this '
          'phone there cuts it off immediately.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
