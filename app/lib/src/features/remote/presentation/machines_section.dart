import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/lifecycle/relaunch.dart';
import '../../../core/server/machine_pairing.dart';
import '../../../core/util/failure_words.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../../system/system_integration_service.dart';
import '../application/machines_providers.dart';

/// Settings → Machines (slice 5e): the Karmashala server this window is a
/// client of — this computer's own, or one on another machine reached like
/// a phone reaches it — the list to choose from, and "Add a machine". A
/// switch starts the window again, as a client of the one chosen.
class MachinesSection extends ConsumerWidget {
  const MachinesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);
    final active = ref.watch(activeMachineProvider);
    final paired = ref.watch(pairedMachinesProvider).value ?? const [];
    final theme = Theme.of(context);
    return SettingsSection(
      title: 'MACHINES',
      trailing: machines == null
          ? null
          : TextButton(
              key: const Key('machines-add'),
              onPressed: () => AddMachineDialog.show(context),
              child: const Text('Add a machine'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MachineRow(
            name: 'This computer',
            detail: 'Its own Karmashala server, started and kept up here.',
            inUse: active == null,
            onUse: machines == null ? null : () => _switch(context, ref, null),
          ),
          for (final machine in paired)
            _MachineRow(
              name: machine.hostName.isEmpty ? 'Server' : machine.hostName,
              detail: _routeOf(machine),
              inUse: active?.hostId == machine.hostId,
              onUse: () => _switch(context, ref, machine),
              onForget: () => _forget(context, ref, machine),
            ),
          if (paired.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                'Use a server on another machine — a droplet, another PC: '
                'run `karmashala_host pair --grants desktop` there, then Add '
                'a machine here.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _routeOf(CompanionPairing machine) {
    final direct = machine.directEndpoint;
    if (direct != null) return 'At $direct';
    final relay = machine.relay;
    return relay.host == 'invalid.local' ? 'Paired' : 'Through ${relay.host}';
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
          'Karmashala starts again as a client of that server. Nothing '
          'running on either server stops.',
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
    if (go != true) return;
    await machines.use(to?.hostId.value);
    await relaunchAfterExit();
    final system = ref.read(systemIntegrationProvider);
    if (system != null) unawaited(system.quit());
  }

  static Future<void> _forget(
    BuildContext context,
    WidgetRef ref,
    CompanionPairing machine,
  ) async {
    final machines = ref.read(machinesProvider);
    if (machines == null) return;
    await machines.forget(machine.hostId.value);
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
  });

  final String name;
  final String detail;
  final bool inUse;
  final VoidCallback? onUse;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) => SettingsRow(
    label: name,
    help: detail,
    control: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (inUse)
          const Chip(label: Text('In use'))
        else if (onUse != null)
          TextButton(onPressed: onUse, child: const Text('Use')),
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
