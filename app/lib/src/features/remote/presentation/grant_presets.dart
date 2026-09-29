import 'package:flutter/material.dart';

import 'package:karmashala_remote/remote.dart';

/// The two starting points for a grant, above the chips for anything finer:
/// the pairing dialog and a paired device's permissions share them.
enum GrantPreset {
  /// The Karmashala app on a phone, and the companion: "all".
  phone('Phone'),

  /// Another machine's desktop app: `desktop_client` plus the phone's
  /// envelope bits. Admin and SSH prompts are ticked only on purpose.
  desktop('Desktop');

  const GrantPreset(this.label);

  final String label;

  CapabilitySet get grants => switch (this) {
    GrantPreset.phone => CapabilitySet.all,
    GrantPreset.desktop => CapabilitySet.of([
      Capability.desktopClient,
      ..._envelope,
    ]),
  };

  /// The chips offered under this preset: the privileged ones only for a
  /// desktop, whose tier they apply to, and the phone bit only for a phone.
  List<Capability> get chips => switch (this) {
    GrantPreset.phone => [
      for (final c in Capability.values)
        if (!c.privileged) c,
    ],
    GrantPreset.desktop => [
      for (final c in Capability.values)
        if (c != Capability.phoneClient) c,
    ],
  };

  /// Which preset [granted] reads as: a desktop's once it holds any
  /// privileged bit, else a phone's.
  static GrantPreset of(CapabilitySet granted) =>
      Capability.values.any((c) => c.privileged && granted.has(c))
      ? GrantPreset.desktop
      : GrantPreset.phone;

  static Iterable<Capability> get _envelope => Capability.values.where(
    (c) => !c.privileged && c != Capability.phoneClient,
  );
}

/// Picks a [GrantPreset].
class GrantPresetPicker extends StatelessWidget {
  const GrantPresetPicker({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final GrantPreset selected;
  final ValueChanged<GrantPreset> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<GrantPreset>(
      showSelectedIcon: false,
      segments: [
        for (final preset in GrantPreset.values)
          ButtonSegment<GrantPreset>(value: preset, label: Text(preset.label)),
      ],
      selected: {selected},
      onSelectionChanged: (choice) => onSelected(choice.first),
    );
  }
}
