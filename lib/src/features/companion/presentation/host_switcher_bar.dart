import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'pairing/pairing_screen.dart';

/// The strip above the session list that names the desktop being shown and
/// switches to another in one tap.
///
/// Deliberately absent with a single saved desktop: a phone paired to one
/// machine must not pay a row of chrome to be told so — Settings still lists
/// it. With two or more, "whose sessions are these" is the question the list
/// cannot answer by itself, so it gets answered here rather than a tab away.
class HostSwitcherBar extends ConsumerWidget {
  const HostSwitcherBar({super.key});

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    List<CompanionConnection> connections,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final connection in connections)
              ListTile(
                leading: Icon(
                  connection.active ? AppIcons.check : AppIcons.deviceMobile,
                  size: Chrome.icon,
                ),
                title: Text(connection.name),
                subtitle: connection.active ? const Text('Active') : null,
                onTap: () => Navigator.of(context).pop(connection.hostId),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(AppIcons.plus, size: Chrome.icon),
              title: const Text('Add a desktop'),
              onTap: () => Navigator.of(context).pop(''),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    if (picked.isEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PairingScreen()),
      );
      return;
    }
    await ref.read(companionSwitchingProvider.notifier).switchTo(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections =
        ref.watch(companionConnectionsProvider).asData?.value ??
        const <CompanionConnection>[];
    if (connections.length < 2) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final switching = ref.watch(companionSwitchingProvider);
    final active = connections.where((c) => c.active).firstOrNull;

    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: switching != null
            ? null
            : () => _choose(context, ref, connections),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          child: Row(
            children: [
              if (switching != null)
                const SizedBox(
                  width: Chrome.icon,
                  height: Chrome.icon,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  AppIcons.deviceMobile,
                  size: Chrome.icon,
                  color: scheme.onSurfaceVariant,
                ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  switching != null
                      ? 'Switching desktop…'
                      : active?.name ?? 'No desktop',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${connections.length} saved',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Insets.xs),
              Icon(
                AppIcons.caretDown,
                size: Chrome.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
