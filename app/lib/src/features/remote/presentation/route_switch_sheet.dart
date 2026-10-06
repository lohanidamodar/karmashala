import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/server/remote_server_access.dart';
import '../../../core/server/server_link.dart';
import '../../terminal/application/local_host_providers.dart';
import '../application/machines_providers.dart';
import 'machine_rename.dart';
import 'machine_route.dart';

/// The quick route switch for the machine in use, opened from where a person
/// looks when the link feels wrong: the route chip in the phone's top bar
/// and *Route…* on the reconnecting strip. It pins through the same
/// [applyMachineRoute] as Settings → Machines — "only", never "prefer".
Future<void> showRouteSwitch(BuildContext context, WidgetRef ref) async {
  if (ref.read(machineInUseProvider) == null) return;
  // The sheet names the machine itself: a rename there shows at once.
  final chosen = await showAdaptiveModal<CompanionRoutePin>(
    context: context,
    title: 'Route',
    builder: (_) => const _RouteSwitchSheet(),
  );
  final machine = ref.read(machineInUseProvider);
  if (chosen == null || machine == null || chosen == machine.pin) return;
  if (!context.mounted) return;
  await applyMachineRoute(context, ref, machine, chosen);
}

class _RouteSwitchSheet extends ConsumerWidget {
  const _RouteSwitchSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machine = ref.watch(machineInUseProvider);
    final access = ref.watch(serverAccessProvider);
    if (machine == null || access is! RemoteServerAccess) {
      return const SizedBox.shrink();
    }
    final link = ref.watch(serverLinkProvider);
    final pin = machine.pin;
    final options = routeOptions(machine);
    return ValueListenableBuilder<bool>(
      valueListenable: access.resuming,
      builder: (context, resuming, _) => ValueListenableBuilder(
        valueListenable: access.route,
        builder: (context, live, _) {
          final down =
              resuming ||
              (live == null && link.state == DataLinkState.unavailable);
          final pinned = options.where((option) => option.pin == pin);
          final theme = Theme.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text(machineName(machine)),
                subtitle: machine.label != null && machine.hostName.isNotEmpty
                    ? Text(machine.hostName)
                    : null,
                trailing: MachineRenameButton(machine: machine),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.lg,
                  vertical: Insets.xs,
                ),
                child: Text(
                  _nowWords(live, resuming: resuming),
                  key: const ValueKey('route-switch-now'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (!pin.isAuto && down && pinned.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.lg,
                    Insets.xs,
                    Insets.lg,
                    Insets.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        AppIcons.warningCircle,
                        size: Chrome.icon,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          "${pinned.first.title} isn't answering. Automatic "
                          'tries every route.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      FilledButton(
                        key: const ValueKey('route-switch-use-auto'),
                        onPressed: () =>
                            Navigator.of(context).pop(CompanionRoutePin.auto),
                        child: const Text('Use Auto'),
                      ),
                    ],
                  ),
                ),
              for (final option in options)
                RouteOptionTile(
                  option: option,
                  current: pin,
                  onTap: () => Navigator.of(context).pop(option.pin),
                ),
            ],
          );
        },
      ),
    );
  }
}

String _nowWords(LiveLinkRoute? live, {required bool resuming}) {
  if (resuming) return 'Now: reconnecting…';
  if (live == null) return 'Now: not connected';
  final relay = live.relay;
  return relay == null
      ? 'Now: on this network'
      : 'Now: through ${relayName(relay)}';
}

/// The route the link is on, by host and port and never by path: "LAN", the
/// relay's host, or "…" with no live link.
String linkRouteLabel(LiveLinkRoute? live) {
  if (live == null) return '…';
  final relay = live.relay;
  if (relay == null) return 'LAN';
  return relay.hasPort ? '${relay.host}:${relay.port}' : relay.host;
}

/// The phone top bar's route chip: the route the machine in use is reached
/// by now, and one tap to [showRouteSwitch]. Nothing on this computer's own
/// server, or for a machine reached at its own address.
class LinkRouteChip extends ConsumerWidget {
  const LinkRouteChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machine = ref.watch(activeMachineProvider);
    final access = ref.watch(serverAccessProvider);
    if (machine == null ||
        !routeIsChoosable(machine) ||
        access is! RemoteServerAccess) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return ValueListenableBuilder<LiveLinkRoute?>(
      valueListenable: access.route,
      builder: (context, live, _) {
        final label = linkRouteLabel(live);
        return Semantics(
          button: true,
          label: 'Route: $label. Change how this machine is reached',
          excludeSemantics: true,
          child: InkWell(
            key: const ValueKey('link-route-chip'),
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => unawaited(showRouteSwitch(context, ref)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      live?.relay == null ? AppIcons.wifiHigh : AppIcons.globe,
                      size: Chrome.iconSmall,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Insets.xs),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// *Route…* on the reconnecting strip, phone and desktop: [showRouteSwitch].
class RouteSwitchButton extends ConsumerWidget {
  const RouteSwitchButton({this.foreground, super.key});

  /// The strip's text colour, where the strip is not on the surface.
  final Color? foreground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machine = ref.watch(activeMachineProvider);
    if (machine == null || !routeIsChoosable(machine)) {
      return const SizedBox.shrink();
    }
    return TextButton(
      key: const ValueKey('remote_route'),
      style: foreground == null
          ? null
          : TextButton.styleFrom(foregroundColor: foreground),
      onPressed: () => unawaited(showRouteSwitch(context, ref)),
      child: const Text('Route…'),
    );
  }
}
