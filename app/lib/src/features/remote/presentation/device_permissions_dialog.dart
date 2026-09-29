import 'package:flutter/material.dart';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';

import 'capability_labels.dart';
import 'grant_presets.dart';

/// Edits what an already-paired phone may do. **No re-pairing**: widening a
/// grant used to mean a fresh code, which threw away the phone's key, its
/// generation and its push registration to say something the device row can
/// say on its own.
class DevicePermissionsDialog extends StatefulWidget {
  const DevicePermissionsDialog({
    required this.deviceName,
    required this.granted,
    super.key,
  });

  final String deviceName;

  /// What the device holds now — the chips start here.
  final CapabilitySet granted;

  /// The new grant, or null when the user cancelled or changed nothing.
  static Future<CapabilitySet?> show(
    BuildContext context,
    String deviceName,
    CapabilitySet granted,
  ) => showDialog<CapabilitySet>(
    context: context,
    builder: (_) =>
        DevicePermissionsDialog(deviceName: deviceName, granted: granted),
  );

  @override
  State<DevicePermissionsDialog> createState() =>
      _DevicePermissionsDialogState();
}

class _DevicePermissionsDialogState extends State<DevicePermissionsDialog> {
  late final Set<Capability> _granted = {
    for (final capability in Capability.values)
      if (widget.granted.has(capability)) capability,
  };

  late GrantPreset _preset = GrantPreset.of(widget.granted);

  void _selectPreset(GrantPreset preset) {
    if (preset == _preset) return;
    setState(() {
      _preset = preset;
      _granted
        ..clear()
        ..addAll(preset.grants.granted);
    });
  }

  bool get _changed =>
      capabilitiesWith(widget.granted, _granted).bits != widget.granted.bits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Permissions'),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What ${widget.deviceName} may do on this desktop. It takes '
              'effect at once — the phone keeps its pairing.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.sm),
            GrantPresetPicker(selected: _preset, onSelected: _selectPreset),
            const SizedBox(height: Insets.sm),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                for (final capability in _preset.chips)
                  FilterChip(
                    label: Text(capabilityLabel(capability)),
                    selected: _granted.contains(capability),
                    onSelected: (value) => setState(() {
                      value
                          ? _granted.add(capability)
                          : _granted.remove(capability);
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _changed
              ? () => Navigator.of(
                  context,
                ).pop(capabilitiesWith(widget.granted, _granted))
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
