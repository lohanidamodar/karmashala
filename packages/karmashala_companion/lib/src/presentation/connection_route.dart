import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/companion.dart';
import '../application/companion_providers.dart';
import 'companion_chrome.dart';
import 'companion_states.dart';

/// What the Route line says. For the active desktop on Automatic it also names
/// the route in use, since that is what a person wants to know before pinning.
String connectionRouteLine(
  CompanionConnection connection, {
  CompanionLinkPath? path,
  Uri? activeRelay,
}) {
  final pin = connection.pin;
  if (pin.isAuto) {
    if (!connection.active || path == null) return 'Route: Automatic';
    final now = path == CompanionLinkPath.lan
        ? 'on this network'
        : 'via ${activeRelay == null ? 'a relay' : describeRelay(activeRelay)}';
    return 'Route: Automatic · $now';
  }
  final gone =
      pin.kind == CompanionRouteKind.relay && !_offers(connection, pin);
  return 'Route: ${describeRoutePin(pin)} (pinned)'
      '${gone ? ' · no longer offered by the desktop' : ''}';
}

bool _offers(CompanionConnection connection, CompanionRoutePin pin) =>
    connection.relays.any((url) => url.toString() == pin.relay.toString());

/// The Route line under a desktop, and the picker behind it. Nothing for a
/// machine paired directly: its route was chosen on the desktop when it was
/// paired, and the row already says which.
class ConnectionRouteLine extends ConsumerWidget {
  const ConnectionRouteLine({required this.connection, super.key});

  final CompanionConnection connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (connection.route != null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final path = connection.active
        ? ref.watch(companionLinkPathProvider).asData?.value
        : null;
    final relay = path == CompanionLinkPath.relay
        ? ref.read(companionGatewayProvider).activeRelay
        : null;
    final pinned = !connection.pin.isAuto;

    return InkWell(
      onTap: () => _pick(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          children: [
            Icon(
              pinned ? AppIcons.pushPinFill : AppIcons.wifiHigh,
              size: density.icon * 0.75,
              color: pinned
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            Flexible(
              child: Text(
                connectionRouteLine(connection, path: path, activeRelay: relay),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: density.muted(theme),
              ),
            ),
            Icon(
              AppIcons.caretRight,
              size: density.icon * 0.75,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final chosen = await showRoutePicker(context, connection);
    if (chosen == null || chosen == connection.pin) return;
    try {
      await ref
          .read(companionGatewayProvider)
          .setRoutePin(connection.hostId, chosen);
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(companionErrorText(error))));
    }
  }
}

/// Every route [connection] can be pinned to, the chosen one ticked. A pinned
/// relay the desktop no longer announces is still listed, so the person can
/// see what they chose, and says so.
Future<CompanionRoutePin?> showRoutePicker(
  BuildContext context,
  CompanionConnection connection,
) {
  final current = connection.pin;
  final relays = [
    for (final url in connection.relays) CompanionRoutePin.relay(url),
    if (current.kind == CompanionRouteKind.relay &&
        !_offers(connection, current))
      current,
  ];
  return companionSheet<CompanionRoutePin>(
    context,
    title: 'HOW TO REACH ${connection.name.toUpperCase()}',
    children: [
      _RouteOption(
        pin: CompanionRoutePin.auto,
        current: current,
        detail: 'This network when the desktop is on it, otherwise a relay.',
      ),
      _RouteOption(
        pin: CompanionRoutePin.lan,
        current: current,
        detail: 'Only while this phone and the desktop share a network.',
      ),
      for (final pin in relays)
        _RouteOption(
          pin: pin,
          current: current,
          detail: _offers(connection, pin)
              ? 'Only this relay, wherever you are.'
              : 'No longer offered by the desktop.',
        ),
    ],
  );
}

class _RouteOption extends StatelessWidget {
  const _RouteOption({
    required this.pin,
    required this.current,
    required this.detail,
  });

  final CompanionRoutePin pin;
  final CompanionRoutePin current;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final selected = pin == current;
    return Semantics(
      selected: selected,
      button: true,
      child: CompanionTouchRow(
        onTap: () => Navigator.of(context).pop(pin),
        leading: Icon(
          selected ? AppIcons.checkCircle : AppIcons.circle,
          size: density.icon,
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(describeRoutePin(pin), style: density.title(theme)),
            Text(detail, style: density.muted(theme)),
          ],
        ),
      ),
    );
  }
}
