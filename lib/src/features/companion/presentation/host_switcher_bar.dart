import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'pairing/pairing_screen.dart';

/// The strip above the session list that names the desktop being shown and
/// switches to another in one tap. Absent with a single saved desktop, which
/// Settings still lists.
class HostSwitcherBar extends ConsumerWidget {
  const HostSwitcherBar({super.key});

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    List<CompanionConnection> connections,
  ) async {
    // Scroll-controlled: a bare Column in Material's half-height sheet
    // overflowed at four desktops, or at two with 200% text.
    final picked = await companionSheet<String>(
      context,
      title: 'DESKTOPS',
      children: [
        for (final connection in connections)
          ListTile(
            leading: Icon(
              connection.active ? AppIcons.check : AppIcons.deviceMobile,
            ),
            title: Text(
              connection.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: connection.active ? const Text('Active') : null,
            selected: connection.active,
            onTap: () => Navigator.of(context).pop(connection.hostId),
          ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(AppIcons.plus),
          title: const Text('Add a desktop'),
          onTap: () => Navigator.of(context).pop(''),
        ),
      ],
    );
    if (picked == null || !context.mounted) return;
    if (picked.isEmpty) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const PairingScreen()));
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
    final density = UiDensity.of(context);
    final switching = ref.watch(companionSwitchingProvider);
    final active = connections.where((c) => c.active).firstOrNull;

    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: switching != null
            ? null
            : () => _choose(context, ref, connections),
        child: Container(
          constraints: density.isTouch
              ? const BoxConstraints(minHeight: Touch.target)
              : null,
          padding: companionListInsets(
            context,
            EdgeInsets.symmetric(
              horizontal: density.padX,
              vertical: density.padY,
            ),
          ),
          child: Row(
            children: [
              if (switching != null)
                SizedBox(
                  width: density.icon,
                  height: density.icon,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  AppIcons.deviceMobile,
                  size: density.icon,
                  color: scheme.onSurfaceVariant,
                ),
              SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
              Expanded(
                child: Text(
                  switching != null
                      ? 'Switching desktop…'
                      : active?.name ?? 'No desktop',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: density.title(theme),
                ),
              ),
              Text('${connections.length} saved', style: density.muted(theme)),
              const SizedBox(width: Insets.xs),
              Icon(
                AppIcons.caretDown,
                size: density.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
