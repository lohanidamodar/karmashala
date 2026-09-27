import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_devices/karmashala_devices.dart';
import '../application/device_ports.dart';
import '../application/device_providers.dart';
import '../application/ios_device_providers.dart';
import 'device_list_row.dart';
import 'device_section_header.dart';

/// How a device starts, in one block under both lists: every choice a switch,
/// and slimming once per platform — it was a tick under iOS only, with
/// Android's behind a dialog. Each row is hidden with nothing for it to govern.
class DeviceStartOptions extends ConsumerWidget {
  const DeviceStartOptions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avds = ref.watch(avdsProvider).asData?.value ?? const <Avd>[];
    final devices =
        ref.watch(devicesProvider).asData?.value ?? const <AndroidDevice>[];
    final idleAvds = avds.any((avd) => !avd.isRunning);
    // The same rule the Emulators heading is drawn by: slimming governs the
    // *next* start, so it outlives the last idle AVD.
    final anyEmulator = avds.isNotEmpty || devices.any((d) => d.isEmulator);

    final canRunSimulators = ref.watch(hostCanRunSimulatorsProvider);
    final startableSimulators =
        canRunSimulators && ref.watch(startableSimulatorsProvider).isNotEmpty;
    final bootedSimulators =
        canRunSimulators && ref.watch(bootedSimulatorsProvider).isNotEmpty;
    final anySimulator = startableSimulators || bootedSimulators;

    final window = idleAvds || startableSimulators;
    if (!window && !anyEmulator && !anySimulator) {
      return const SizedBox.shrink();
    }

    // Read when a switch is flipped, not while building: the app keeps these
    // in its settings store, and drawing the pane must not be what opens it.
    DeviceSlimmingPreferences preferences() =>
        ref.read(deviceSlimmingPreferencesProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: DeviceListMetrics.sectionGap),
        const DeviceSectionHeader(title: 'When starting'),
        if (window)
          DeviceSwitchRow(
            key: const Key('headless-emulator-toggle'),
            label: 'Start without a window',
            // Worded by promise: the mechanics differ per OS.
            help: idleAvds && startableSimulators
                ? 'Watch it here instead. Turn off for the emulator\'s '
                      'extended controls, or the Simulator app.'
                : startableSimulators
                ? 'Watch it here instead. Turn off to open the Simulator app '
                      'too.'
                : 'Watch it here instead. Turn off for the emulator\'s own '
                      'extended controls.',
            value: ref.watch(headlessDeviceProvider),
            onChanged: (value) =>
                ref.read(headlessDeviceProvider.notifier).update(value),
          ),
        if (anyEmulator)
          DeviceSwitchRow(
            key: const Key('android-slim-on-start'),
            label: 'Slim emulators on start',
            help: _emulatorHelp(ref),
            value: ref.watch(androidSlimmingOnStartProvider),
            onChanged: (value) => preferences().setAndroidSlimming(value),
          ),
        if (anySimulator)
          DeviceSwitchRow(
            key: const Key('slim-on-start'),
            label: 'Slim simulators on start',
            help: _simulatorHelp(ref, booted: bootedSimulators),
            value: ref.watch(slimmingOnStartProvider),
            onChanged: (value) => preferences().setSimulatorSlimming(value),
          ),
      ],
    );
  }

  static String _emulatorHelp(WidgetRef ref) {
    if (!ref.watch(androidSlimmingOnStartProvider)) {
      return 'Starts as the AVD is set up.';
    }
    final chosen = ref.watch(androidSlimmingCategoriesProvider).length;
    return chosen == 0
        ? 'Nothing is chosen yet — pick what to trim with the gear above.'
        : 'Trims $chosen of ${AndroidSlimmingCategory.values.length} groups. '
              'Choose which with the gear above.';
  }

  /// launchd reads `disabled.plist` at boot, so this can only apply to a
  /// simulator that is *starting* — and while one runs, the row says so.
  static String _simulatorHelp(WidgetRef ref, {required bool booted}) {
    if (!ref.watch(slimmingOnStartProvider)) {
      return 'Starts with every background service iOS ships.';
    }
    final kept = ref.watch(slimmingKeptCategoriesProvider);
    final trimmed = SlimmingCategory.values.length - kept.length;
    final base =
        'Starts without $trimmed groups of background services. Choose '
        'which with the gear above.';
    return booted
        ? '$base A running simulator keeps the services it booted with. '
              'Stop and start it to slim it.'
        : base;
  }
}
