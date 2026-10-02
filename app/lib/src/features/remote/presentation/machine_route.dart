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

String _capitalised(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

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

/// Opens the route picker for [machine] and applies what is picked through
/// [RoutePinController.choose], which redials when [machine] is in use.
Future<void> pickMachineRoute(
  BuildContext context,
  WidgetRef ref,
  CompanionPairing machine,
) async {
  final name = machine.hostName.isEmpty ? 'the server' : machine.hostName;
  final current = machine.pin;
  final relays = knownRelays(machine);
  final pinnedGone =
      current.kind == CompanionRouteKind.relay &&
      !relays.any((url) => url.toString() == current.relay.toString());
  final chosen = await showAdaptiveModal<CompanionRoutePin>(
    context: context,
    title: 'How to reach $name',
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RouteOption(
          pin: CompanionRoutePin.auto,
          current: current,
          title: 'Automatic',
          detail: 'This network when $name is on it, otherwise a relay.',
        ),
        _RouteOption(
          pin: CompanionRoutePin.lan,
          current: current,
          title: 'This network only',
          detail: 'Only while this device and $name share a network.',
        ),
        for (final url in relays)
          _RouteOption(
            pin: CompanionRoutePin.relay(url),
            current: current,
            title: _capitalised(relayName(url)),
            detail: 'Only this relay, wherever you are.',
          ),
        if (pinnedGone)
          _RouteOption(
            pin: current,
            current: current,
            title: _capitalised(relayName(current.relay!)),
            detail: 'No longer announced by $name.',
          ),
      ],
    ),
  );
  if (chosen == null || chosen == current || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref
        .read(routePinProvider.notifier)
        .choose(chosen, hostId: machine.hostId.value);
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text('The route was not saved: ${describeFailure(error)}'),
      ),
    );
  }
}

class _RouteOption extends StatelessWidget {
  const _RouteOption({
    required this.pin,
    required this.current,
    required this.title,
    required this.detail,
  });

  final CompanionRoutePin pin;
  final CompanionRoutePin current;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final selected = pin == current;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      leading: Icon(
        selected ? AppIcons.checkCircle : AppIcons.circle,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(title),
      subtitle: Text(detail),
      onTap: () => Navigator.of(context).pop(pin),
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
