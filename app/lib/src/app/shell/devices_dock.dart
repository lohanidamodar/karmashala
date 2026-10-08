import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/presentation/sidebar_chrome.dart';
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
///
/// Drawn on the sidebar's own tone, not a band of its own: the group label
/// says where it starts, and the structural hairline above it is transparent
/// unless the user chose borders (spec §2, "Tone, not lines").
class DevicesDock extends StatelessWidget {
  const DevicesDock({required this.devices, required this.onOpen, super.key});

  final List<DockDevice> devices;
  final ValueChanged<DockDevice?> onOpen;

  /// Rows drawn before the rest fold into "n more".
  static const visibleRows = 3;

  /// The dock's own padding: the list's sides, a little air above the label
  /// and the list's 8 under the last row (board A2 `padding: 6px 6px 8px`,
  /// less the 4 every row insets its fill).
  static const padding = EdgeInsets.fromLTRB(
    Insets.xxs,
    Insets.xsm,
    Insets.xxs,
    Insets.sm,
  );

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    final shown = devices.take(visibleRows).toList();
    final hidden = devices.length - shown.length;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tones.line)),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SidebarGroupLabel(
              label: 'Devices',
              leading: const Icon(AppIcons.deviceMobile),
              tooltip: 'Open Devices',
              onTap: () => onOpen(null),
              count: devices.isEmpty
                  ? 'none'
                  : hidden > 0
                  ? '$hidden more'
                  : '${devices.length}',
            ),
            for (final device in shown)
              _DockLine(
                key: ValueKey('dock-device:${device.id}'),
                device: device,
                onTap: () => onOpen(device),
              ),
          ],
        ),
      ),
    );
  }
}

/// One device on the sidebar's row (`.row`): 28px, radius 6, its state dot,
/// its name, and — muted — what kind of device it is.
class _DockLine extends StatelessWidget {
  const _DockLine({required this.device, required this.onTap, super.key});

  final DockDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final kind = device.simulator
        ? 'simulator'
        : device.emulator
        ? 'emulator'
        : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ExplorerRow.inset,
        0,
        ExplorerRow.inset,
        Sidebar.rowGap,
      ),
      child: Tooltip(
        message: [
          device.name,
          if (device.emulator) 'emulator',
          if (!device.ready) 'not connected',
        ].join(' · '),
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
          hoverColor: StateLayers.hover(scheme),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Sidebar.rowHeight),
            child: Padding(
              padding: EdgeInsets.only(
                left: Sidebar.labelPadX,
                right: Sidebar.labelTrailOf(density),
              ),
              child: Row(
                children: [
                  Icon(
                    AppIcons.circleFill,
                    size: Chrome.dot,
                    semanticLabel: device.ready ? 'connected' : 'offline',
                    color: device.ready
                        ? SemanticColors.of(context).idle
                        : SurfaceTones.of(context).floatingLine,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: density.rowTitle(theme),
                    ),
                  ),
                  if (kind != null) ...[
                    const SizedBox(width: Insets.sm),
                    Text(
                      kind,
                      maxLines: 1,
                      style: density
                          .muted(theme)
                          ?.copyWith(color: scheme.outline),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
