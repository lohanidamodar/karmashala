import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import 'shell_area.dart';

/// One device as the dock draws it.
@immutable
class DockDevice {
  const DockDevice({
    required this.id,
    required this.name,
    required this.emulator,
    required this.ready,
    this.simulator = false,
  });

  /// The serial (Android) or UDID (simulator).
  final String id;
  final String name;

  /// An emulator or simulator, not a handset on a cable or Wi-Fi.
  final bool emulator;

  /// Connected and answering, rather than offline or unauthorised.
  final bool ready;

  /// An iOS simulator, picked by UDID rather than by adb serial.
  final bool simulator;

  @override
  bool operator ==(Object other) =>
      other is DockDevice &&
      other.id == id &&
      other.name == name &&
      other.emulator == emulator &&
      other.ready == ready &&
      other.simulator == simulator;

  @override
  int get hashCode => Object.hash(id, name, emulator, ready, simulator);
}

/// Every device the dock lists: Android devices and emulators, then booted
/// simulators. Never asks adb itself — the Devices area and its refresh do.
final dockDevicesProvider = Provider<List<DockDevice>>((ref) {
  final android = ref.watch(devicesProvider).asData?.value ?? const [];
  final simulators = ref.watch(hostCanRunSimulatorsProvider)
      ? ref.watch(bootedSimulatorsProvider)
      : const <IosSimulator>[];
  return [
    for (final device in android)
      DockDevice(
        id: device.serial,
        name: device.displayName,
        emulator: device.isEmulator,
        ready: device.isReady,
      ),
    for (final simulator in simulators)
      DockDevice(
        id: simulator.udid,
        name: simulator.name,
        emulator: true,
        ready: true,
        simulator: true,
      ),
  ];
});

/// How many devices are connected and ready — the strip's Devices badge.
final readyDeviceCountProvider = Provider<int>(
  (ref) => ref.watch(dockDevicesProvider).where((d) => d.ready).length,
);

/// **The Devices dock** (spec §4): the foot of every sidebar area but
/// Devices, so a phone is one click away from wherever the user is.
class ShellDevicesDock extends ConsumerWidget {
  const ShellDevicesDock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DevicesDock(
    devices: ref.watch(dockDevicesProvider),
    onOpen: (device) {
      if (device != null && device.simulator) {
        ref.read(selectedSimulatorUdidProvider.notifier).select(device.id);
      } else if (device != null) {
        ref.read(selectedDeviceSerialProvider.notifier).select(device.id);
      }
      ref.read(shellAreaProvider.notifier).select(ShellArea.devices);
    },
  );
}

/// The dock from values: the devices, and what opening one (or the header,
/// with null) does.
class DevicesDock extends StatelessWidget {
  const DevicesDock({required this.devices, required this.onOpen, super.key});

  final List<DockDevice> devices;
  final ValueChanged<DockDevice?> onOpen;

  /// Rows drawn before the rest fold into "n more".
  static const visibleRows = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final shown = devices.take(visibleRows).toList();
    final hidden = devices.length - shown.length;
    return ColoredBox(
      color: tones.chrome,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DockLine(
              onTap: () => onOpen(null),
              tooltip: 'Open Devices',
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'DEVICES',
                      style: muted?.merge(Chrome.groupLabel),
                    ),
                  ),
                  Text(
                    devices.isEmpty
                        ? 'none'
                        : hidden > 0
                        ? '$hidden more'
                        : '${devices.length}',
                    style: muted,
                  ),
                ],
              ),
            ),
            for (final device in shown)
              _DockLine(
                key: ValueKey('dock-device:${device.id}'),
                onTap: () => onOpen(device),
                tooltip: [
                  device.name,
                  if (device.emulator) 'emulator',
                  if (!device.ready) 'not connected',
                ].join(' · '),
                child: Row(
                  children: [
                    Icon(
                      AppIcons.deviceMobile,
                      size: Chrome.iconSmall,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Icon(
                      AppIcons.circleFill,
                      size: 7,
                      semanticLabel: device.ready ? 'connected' : 'offline',
                      color: device.ready
                          ? SemanticColors.of(context).working
                          : theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DockLine extends StatelessWidget {
  const _DockLine({
    required this.onTap,
    required this.tooltip,
    required this.child,
    super.key,
  });

  final VoidCallback onTap;
  final String tooltip;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 26,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
          child: child,
        ),
      ),
    ),
  );
}
