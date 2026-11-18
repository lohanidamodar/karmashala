import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairing;

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/remote/application/machines_providers.dart';
import '../../features/remote/presentation/machine_route.dart'
    show machineRouteLine;
import '../../features/remote/presentation/machine_switch.dart';
import '../../features/settings/presentation/settings_catalog.dart'
    show SettingsAnchor;
import 'workbench_tabs.dart' show openSettingsTab;

/// What a pick in the title bar's machine menu asks for.
sealed class _MachinePick {
  const _MachinePick();
}

final class _Use extends _MachinePick {
  const _Use(this.machine);

  /// Null for this computer's own server.
  final CompanionPairing? machine;
}

final class _Add extends _MachinePick {
  const _Add();
}

final class _Manage extends _MachinePick {
  const _Manage();
}

/// The title bar's `<machine> ▾`: which server this window is a client of,
/// and one click to another — the switch Settings › Machines makes, without
/// going there. Drawn only once there is another machine to choose.
class MachinePickerButton extends ConsumerWidget {
  const MachinePickerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(machinesProvider) == null) return const SizedBox.shrink();
    final active = ref.watch(machineInUseProvider);
    final paired = ref.watch(pairedMachinesProvider).value ?? const [];
    if (active == null && paired.isEmpty) return const SizedBox.shrink();
    final name = machinePickName(active);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: Chrome.titleBarMachineMaxWidth,
      ),
      child: Tooltip(
        message: 'Server: $name\nSwitch machine',
        child: Semantics(
          button: true,
          label: 'Server: $name. Switch or add a machine',
          excludeSemantics: true,
          child: Builder(
            builder: (anchor) => InkWell(
              key: const ValueKey('title-bar-machine'),
              borderRadius: BorderRadius.circular(Radii.sm),
              onTap: () => _open(anchor, ref),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: Insets.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                    Icon(
                      AppIcons.caretDown,
                      size: Chrome.iconSmall,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext anchor, WidgetRef ref) async {
    final choices = machinePickChoices(ref);
    final active = ref.read(activeMachineProvider);
    final pick = await showDesktopMenuUnder<_MachinePick>(anchor, [
      DesktopMenuHeader('Machines'),
      for (final machine in choices)
        DesktopMenuDetailItem(
          value: _Use(machine),
          label: machinePickName(machine),
          detail: machine == null
              ? 'Its own Karmashala server'
              : machineRouteLine(
                  machine,
                  inUse: machine.hostId == active?.hostId,
                ),
          detailMaxLines: 1,
          selected: machine?.hostId == active?.hostId,
        ),
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: const _Add(),
        label: 'Add a machine…',
        icon: AppIcons.plus,
      ),
      DesktopMenuItem(
        value: const _Manage(),
        label: 'Manage machines…',
        icon: AppIcons.gearSix,
      ),
    ]);
    if (!anchor.mounted) return;
    switch (pick) {
      case _Use(:final machine):
        await useMachine(anchor, ref, machine);
      case _Add():
        await addMachine(anchor, ref);
      case _Manage():
        openSettingsTab(ref, anchor: SettingsAnchor.machines);
      case null:
        break;
    }
  }
}
