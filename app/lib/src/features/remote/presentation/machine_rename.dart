import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart';

import '../../../core/util/failure_words.dart';
import '../application/machines_providers.dart';

/// Renames [machine] on this client only, like a contact: the machine keeps
/// its own name, which stays beside the label, and nothing is sent to it.
/// Saving a blank name, or *Use the machine's name*, clears the label.
Future<void> renameMachine(
  BuildContext context,
  WidgetRef ref,
  CompanionPairing machine,
) async {
  final machines = ref.read(machinesProvider);
  if (machines == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final chosen = await showDialog<_Rename>(
    context: context,
    builder: (_) => _RenameDialog(machine: machine),
  );
  if (chosen == null) return;
  // The machine's own name, kept as typed, is no label at all.
  final label = chosen.label == machine.hostName ? null : chosen.label;
  try {
    await machines.rename(machine.hostId.value, label);
    ref.invalidate(pairedMachinesProvider);
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text('The name was not saved: ${describeFailure(error)}'),
      ),
    );
  }
}

/// What the dialog chose: a label, or null for the machine's own name.
typedef _Rename = ({String? label});

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.machine});

  final CompanionPairing machine;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.machine.displayName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() =>
      Navigator.of(context).pop((label: normaliseMachineLabel(_name.text)));

  @override
  Widget build(BuildContext context) {
    final own = widget.machine.hostName.isEmpty
        ? 'the server'
        : widget.machine.hostName;
    return AlertDialog(
      title: const Text('Rename machine'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('machine-rename-field'),
              controller: _name,
              autofocus: true,
              maxLength: kMachineLabelMaxLength,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            Text(
              'Only on this device. The machine calls itself $own.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        if (widget.machine.label != null)
          TextButton(
            key: const ValueKey('machine-rename-clear'),
            onPressed: () => Navigator.of(context).pop((label: null)),
            child: const Text("Use the machine's name"),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('machine-rename-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// *Rename…* for [machine]: [renameMachine].
class MachineRenameButton extends ConsumerWidget {
  const MachineRenameButton({required this.machine, super.key});

  final CompanionPairing machine;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    key: ValueKey('machine-rename-${machine.hostId.value}'),
    onPressed: () => unawaited(renameMachine(context, ref, machine)),
    child: const Text('Rename…'),
  );
}
