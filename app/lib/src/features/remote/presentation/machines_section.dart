import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/lifecycle/relaunch.dart';
import '../../../core/lifecycle/server_switcher.dart';
import '../../../core/paths/app_support_directory.dart';
import '../../../core/server/machine_pairing.dart';
import '../../../core/util/failure_words.dart';
import '../../explorer/application/session_list_snapshot.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../../system/system_integration_service.dart';
import '../application/machines_providers.dart';
import 'machine_route.dart';
import 'pair_machine_page.dart';

/// Settings → Machines (slice 5e): the Karmashala server this window is a
/// client of — this computer's own, or one on another machine reached like
/// a phone reaches it — the list to choose from, and "Add a machine". A
/// switch makes this window a client of the one chosen, in process
/// ([ServerSwitcher]).
class MachinesSection extends ConsumerWidget {
  const MachinesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final active = ref.watch(activeMachineProvider);
    final paired = ref.watch(pairedMachinesProvider).value ?? const [];
    // A phone has no server of its own to offer, and pairs on its own page.
    final client = ref.watch(clientCapabilitiesProvider);
    final hostsServer = client.hostsServer;
    final pairCommand = hostsServer
        ? '`karmashala_host pair --grants desktop`'
        : '`karmashala_host pair`';
    // Board rows: a row per server, then adding one as the list's last row.
    return SettingsSection(
      title: 'MACHINES',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hostsServer)
            _MachineRow(
              name: 'This computer',
              detail: 'Its own Karmashala server, started and kept up here.',
              inUse: active == null,
              onUse: machines == null
                  ? null
                  : () => _switch(context, ref, null),
            ),
          for (final machine in paired)
            _MachineRow(
              name: machine.hostName.isEmpty ? 'Server' : machine.hostName,
              detail: machineRouteLine(
                machine,
                inUse: active?.hostId == machine.hostId,
              ),
              inUse: active?.hostId == machine.hostId,
              route: routeIsChoosable(machine)
                  ? MachineRouteButton(machine: machine)
                  : null,
              onUse: () => _switch(context, ref, machine),
              onForget: () => _forget(context, ref, machine),
            ),
          if (machines != null)
            SettingsRow(
              label: 'A server on another machine',
              help: paired.isEmpty
                  ? 'A droplet, another PC: run $pairCommand there, then add '
                        'it here.'
                  : null,
              control: OutlinedButton(
                key: const Key('machines-add'),
                onPressed: hostsServer
                    ? () => AddMachineDialog.show(context)
                    : () => PairMachinePage.push(
                        context,
                        machines: machines,
                        client: client,
                        switcher: ref.read(serverSwitcherProvider),
                        onListChanged: () =>
                            ref.invalidate(pairedMachinesProvider),
                      ),
                child: const Text('Add a machine'),
              ),
            )
          else if (paired.isEmpty)
            SettingsNote(
              'Use a server on another machine — a droplet, another PC: '
              'run $pairCommand there, then Add a machine here.',
            ),
        ],
      ),
    );
  }

  static Future<void> _switch(
    BuildContext context,
    WidgetRef ref,
    CompanionPairing? to,
  ) async {
    final machines = ref.read(machinesProvider);
    if (machines == null) return;
    final name = to?.hostName ?? 'this computer';
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
    // In process (plan step 14): this section's tree goes with the old
    // server, so nothing below reads `ref` once the switch has begun.
    final switcher = ref.read(serverSwitcherProvider);
    if (switcher == null) {
      // No switcher in this process: start afresh, as before step 14.
      await machines.use(to?.hostId.value);
      await relaunchAfterExit();
      final system = ref.read(systemIntegrationProvider);
      if (system != null) unawaited(system.quit());
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final outcome = await switcher.switchTo(to);
    if (outcome == ServerSwitchOutcome.busy) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('A switch is already under way.')),
      );
    }
  }

  static Future<void> _forget(
    BuildContext context,
    WidgetRef ref,
    CompanionPairing machine,
  ) async {
    final machines = ref.read(machinesProvider);
    if (machines == null) return;
    final hostId = machine.hostId.value;
    await machines.forget(hostId);
    // Its last session list goes with it. Forget is never offered for the
    // machine in use, so no open list is saving to that folder.
    try {
      await SessionListSnapshotStore.deleteFor(
        await appSupportDirectory(),
        hostId,
      );
    } on Object {
      // No folder to look in: nothing was saved.
    }
    if (!context.mounted) return;
    ref.invalidate(pairedMachinesProvider);
  }
}

class _MachineRow extends StatelessWidget {
  const _MachineRow({
    required this.name,
    required this.detail,
    required this.inUse,
    this.onUse,
    this.onForget,
    this.route,
  });

  final String name;
  final String detail;
  final bool inUse;
  final VoidCallback? onUse;
  final VoidCallback? onForget;

  /// *Route…*, on a paired machine whose route can be chosen.
  final Widget? route;

  @override
  Widget build(BuildContext context) => SettingsRow(
    label: name,
    help: detail,
    // Buttons and a chip: at their own width under the label, not stretched.
    stackedFit: SettingsControlFit.start,
    control: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // A value, not a chip: the board states a fact in a pill.
        if (inUse)
          const SettingsValue(label: 'In use')
        else if (onUse != null)
          TextButton(onPressed: onUse, child: const Text('Use')),
        ?route,
        if (onForget != null && !inUse)
          TextButton(onPressed: onForget, child: const Text('Forget')),
      ],
    ),
  );
}

/// "Add a machine": the code a server's `pair --grants desktop` printed (or
/// its payload), and the address it is reached at — as a phone adds one.
class AddMachineDialog extends ConsumerStatefulWidget {
  const AddMachineDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const AddMachineDialog(),
  );

  @override
  ConsumerState<AddMachineDialog> createState() => _AddMachineDialogState();
}

class _AddMachineDialogState extends ConsumerState<AddMachineDialog> {
  final _code = TextEditingController();
  final _address = TextEditingController();
  var _busy = false;
  String? _error;
  CompanionPairing? _paired;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final machines = ref.read(machinesProvider);
    if (machines == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final record = await pairWithMachine(
        store: machines.store,
        code: _code.text,
        address: _address.text,
        deviceName: ref.read(clientCapabilitiesProvider).deviceName,
      );
      ref.invalidate(pairedMachinesProvider);
      if (mounted) setState(() => _paired = record);
    } on CompanionPairingException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Pairing failed: ${describeFailure(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paired = _paired;
    if (paired != null) {
      return AlertDialog(
        title: const Text('Machine added'),
        content: Text(
          '${paired.hostName.isEmpty ? 'The server' : paired.hostName} is '
          'paired. Switch to it from Settings → Machines.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('Add a machine'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'On the server run `karmashala_host pair --grants desktop` '
              '(add `--address=<its address>` for a code that says where it '
              'is), then paste the code or the payload it printed.',
            ),
            const SizedBox(height: Insets.sm),
            TextField(
              key: const Key('add-machine-code'),
              controller: _code,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Code or payload'),
            ),
            const SizedBox(height: Insets.xs),
            TextField(
              key: const Key('add-machine-address'),
              controller: _address,
              decoration: const InputDecoration(
                labelText: 'Address (host:port), if the code names none',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.sm),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('add-machine-pair'),
          onPressed: _busy ? null : _pair,
          child: Text(_busy ? 'Pairing…' : 'Pair'),
        ),
      ],
    );
  }
}
