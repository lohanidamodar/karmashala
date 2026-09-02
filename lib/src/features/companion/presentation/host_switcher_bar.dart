import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_chrome.dart';
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
    // Scroll-controlled and titled like every other companion sheet: a bare
    // Column in Material's half-height sheet overflowed as soon as a phone
    // had four desktops, and at 200% text it overflowed with two.
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
