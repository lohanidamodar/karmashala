import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairing;

import '../../../core/capabilities/capabilities.dart';
import '../../../core/lifecycle/relaunch.dart';
import '../../../core/lifecycle/server_switcher.dart';
import '../../system/system_integration_service.dart';
import '../application/machines_providers.dart';
import 'machine_route.dart' show machineName;
import 'machines_section.dart' show AddMachineDialog;
import 'pair_machine_page.dart';

/// What a machine is called wherever one is picked: "This computer" for this
/// computer's own server (null), else its label or host name.
String machinePickName(CompanionPairing? machine) =>
    machine == null ? 'This computer' : machineName(machine);

/// The machines a picker offers, in its order: this computer where it hosts
/// a server, then every paired machine. Each is null for this computer.
List<CompanionPairing?> machinePickChoices(WidgetRef ref) => [
  if (ref.read(clientCapabilitiesProvider).hostsServer) null,
  ...?ref.read(pairedMachinesProvider).value,
];

/// Whether [machine] is the one this window is a client of now.
bool machineInUse(WidgetRef ref, CompanionPairing? machine) =>
    machine?.hostId == ref.read(activeMachineProvider)?.hostId;

/// Makes this window a client of [to] (null: this computer's own server) —
/// the one switch every picker shares: the title bar's, the phone's, quick
/// open's and Settings › Machines'. In process ([ServerSwitcher]) where this
/// process has a switcher, else by a relaunch into it.
///
/// [confirm] asks first, naming what is replaced. A pick from a list of
/// machines is already the ask; a button that does not name the machine is
/// not.
Future<void> useMachine(
  BuildContext context,
  WidgetRef ref,
  CompanionPairing? to, {
  bool confirm = false,
}) async {
  final machines = ref.read(machinesProvider);
  if (machines == null) return;
  if (machineInUse(ref, to)) return;
  if (confirm) {
    final name = machinePickName(to);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Use $name?'),
        content: const Text(
          'This window becomes a client of that server: its panes, sessions '
          'and notes replace these. Nothing running on either server stops.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
  }
  // This tree goes with the old server: nothing below reads `ref` once the
  // switch has begun, so everything it needs is read now.
  final switcher = ref.read(serverSwitcherProvider);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (switcher == null) {
    // No switcher in this process: start afresh, as before step 14.
    final system = ref.read(systemIntegrationProvider);
    await machines.use(to?.hostId.value);
    await relaunchAfterExit();
    if (system != null) unawaited(system.quit());
    return;
  }
  final outcome = await switcher.switchTo(to);
  if (outcome == ServerSwitchOutcome.busy) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('A switch is already under way.')),
    );
  }
}

/// Pairs another machine: the desktop's dialog where this client hosts a
/// server, else the phone's pairing page (scan, paste, address).
Future<void> addMachine(BuildContext context, WidgetRef ref) {
  final client = ref.read(clientCapabilitiesProvider);
  final machines = ref.read(machinesProvider);
  if (client.hostsServer || machines == null) {
    return AddMachineDialog.show(context);
  }
  return PairMachinePage.push(
    context,
    machines: machines,
    client: client,
    switcher: ref.read(serverSwitcherProvider),
    onListChanged: () => ref.invalidate(pairedMachinesProvider),
  );
}
