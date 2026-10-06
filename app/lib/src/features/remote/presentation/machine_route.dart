import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_ui/icons.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/util/failure_words.dart';
import '../application/route_pin_controller.dart';

/// How a paired machine is reached, as its row in Settings → Machines and
/// the phone's machine list say it, and the picker that pins it — the old
/// companion's Route line and `showRoutePicker` (`connection_route.dart`),
/// re-drawn with the app's rows.

/// The relays [machine] knows — the one it paired through and every one the
/// server announced since — without the `invalid.local` placeholder of a
/// pairing made with none.
List<Uri> knownRelays(CompanionPairing machine) => [
  for (final candidate in machine.candidates)
    if (candidate.url.host != 'invalid.local') candidate.url,
];

/// A relay by where it is, and **never by its path**: a relay on the owner's
/// own box carries its access token there, and a label gets screenshotted.
String relayName(Uri url) {
  if (url.host == defaultCompanionRelay?.host) {
    return 'the hosted relay';
  }
  final at = url.hasPort ? '${url.host}:${url.port}' : url.host;
  return isLocalRelay(url)
      ? 'the relay on this network at $at'
      : 'the relay at $at';
}

String capitalised(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

/// What this client calls [machine]: its label, else its own name, else
/// [fallback].
String machineName(CompanionPairing machine, {String fallback = 'Server'}) {
  final name = machine.displayName.trim();
  return name.isEmpty ? fallback : name;
}

/// Whether [machine] can have its route chosen: not one paired at its own
/// address, which is always dialled first and was chosen at pairing.
bool routeIsChoosable(CompanionPairing machine) =>
    machine.directEndpoint == null;

/// What [machine]'s row says about its route. On Automatic the dialer still
/// picks — this network first, then the known relays by health — so the line
/// says so, and for the machine in use how its last dial got there. That is
/// read from the saved record (the relay a dial went through is marked at the
/// same instant as the link), not the live socket: a link later moved onto
/// this network is not seen here.
String machineRouteLine(CompanionPairing machine, {bool inUse = false}) {
  final direct = machine.directEndpoint;
  if (direct != null) return 'At $direct';
  final relays = knownRelays(machine);
  final pin = machine.pin;
  switch (pin.kind) {
    case CompanionRouteKind.lan:
      return 'This network only (pinned)';
    case CompanionRouteKind.relay:
      final url = pin.relay!;
      final offered = relays.any((known) => known.toString() == url.toString());
      return 'Only through ${relayName(url)} (pinned)'
          '${offered ? '' : ' · no longer announced by the server'}';
    case CompanionRouteKind.auto:
      final parts = <String>[
        'Automatic',
        switch (relays.length) {
          0 => 'this network only, no relay known',
          1 => 'this network, then 1 relay',
          final n => 'this network, then $n relays',
        },
      ];
      if (inUse) {
        final last = _lastDial(machine);
        if (last != null) parts.add('last reached $last');
      }
      return parts.join(' · ');
  }
}

/// How the last dial reached [machine], or null when none is recorded.
String? _lastDial(CompanionPairing machine) {
  final at = machine.lastConnectedAt;
  if (at == null) return null;
  for (final candidate in machine.candidates) {
    final ok = candidate.lastSuccessAt;
    if (ok != null && ok.isAtSameMomentAs(at)) {
      return 'through ${relayName(candidate.url)}';
    }
  }
  return 'on this network';
}

/// One route a machine can be pinned to, as both route pickers list it.
typedef RouteOption = ({CompanionRoutePin pin, String title, String detail});

/// Every route [machine] can be pinned to: Automatic, this network, each
/// relay it knows by host and port, and a pinned relay its server no longer
/// announces.
List<RouteOption> routeOptions(CompanionPairing machine) {
  final name = machineName(machine, fallback: 'the server');
  final current = machine.pin;
  final relays = knownRelays(machine);
  final pinnedGone =
      current.kind == CompanionRouteKind.relay &&
      !relays.any((url) => url.toString() == current.relay.toString());
  return [
    (
      pin: CompanionRoutePin.auto,
      title: 'Automatic',
      detail: 'This network when $name is on it, otherwise a relay.',
    ),
    (
      pin: CompanionRoutePin.lan,
      title: 'This network only',
      detail: 'Only while this device and $name share a network.',
    ),
    for (final url in relays)
      (
        pin: CompanionRoutePin.relay(url),
        title: capitalised(relayName(url)),
        detail: 'Only this relay, wherever you are.',
      ),
    if (pinnedGone)
      (
        pin: current,
        title: capitalised(relayName(current.relay!)),
        detail: 'No longer announced by $name.',
      ),
  ];
}

/// Opens the route picker for [machine] and applies what is picked through
/// [applyMachineRoute].
Future<void> pickMachineRoute(
  BuildContext context,
  WidgetRef ref,
  CompanionPairing machine,
) async {
  final name = machineName(machine, fallback: 'the server');
  final current = machine.pin;
  final chosen = await showAdaptiveModal<CompanionRoutePin>(
    context: context,
    title: 'How to reach $name',
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in routeOptions(machine))
          RouteOptionTile(
            option: option,
            current: current,
            onTap: () => Navigator.of(context).pop(option.pin),
          ),
      ],
    ),
  );
  if (chosen == null || chosen == current || !context.mounted) return;
  await applyMachineRoute(context, ref, machine, chosen);
}

/// Pins [machine] to [pin] through [RoutePinController.choose] — the one way
/// any picker changes a route — which redials when [machine] is in use.
Future<void> applyMachineRoute(
  BuildContext context,
  WidgetRef ref,
  CompanionPairing machine,
  CompanionRoutePin pin,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref
        .read(routePinProvider.notifier)
        .choose(pin, hostId: machine.hostId.value);
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text('The route was not saved: ${describeFailure(error)}'),
      ),
    );
  }
}

/// A [RouteOption] as a row, ticked when it is [current].
class RouteOptionTile extends StatelessWidget {
  const RouteOptionTile({
    required this.option,
    required this.current,
    required this.onTap,
    super.key,
  });

  final RouteOption option;
  final CompanionRoutePin current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = option.pin == current;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      leading: Icon(
        selected ? AppIcons.checkCircle : AppIcons.circle,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(option.title),
      subtitle: Text(option.detail),
      onTap: onTap,
    );
  }
}

/// *Route…* on a paired machine's row: opens [pickMachineRoute].
class MachineRouteButton extends ConsumerWidget {
  const MachineRouteButton({required this.machine, super.key});

  final CompanionPairing machine;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    key: ValueKey('machine-route-${machine.hostId.value}'),
    onPressed: () => unawaited(pickMachineRoute(context, ref, machine)),
    child: const Text('Route…'),
  );
}
