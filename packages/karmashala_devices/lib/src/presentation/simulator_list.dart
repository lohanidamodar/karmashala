import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';

import '../application/ios_device_providers.dart';
import 'device_list_row.dart';
import 'device_section_header.dart';
import 'simulator_slimming_dialog.dart';

/// The iOS Simulators section: the same rows the emulators are, each with its
/// own Start. Xcode accumulates 170 here, so the list is folded to the newest
/// few until asked for. Off macOS the section disappears entirely.
class SimulatorList extends ConsumerStatefulWidget {
  const SimulatorList({super.key});

  /// How many simulators are listed before `Show all`. They arrive newest
  /// runtime first, so these are the ones a person most likely meant.
  static const folded = 5;

  @override
  ConsumerState<SimulatorList> createState() => _SimulatorListState();
}

class _SimulatorListState extends ConsumerState<SimulatorList> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(hostCanRunSimulatorsProvider)) {
      return const SizedBox.shrink();
    }
    final anyBooted = ref.watch(bootedSimulatorsProvider).isNotEmpty;
    final startable = ref.watch(startableSimulatorsProvider);
    final busy = ref.watch(simulatorTransitionsProvider);
    final transitions = ref.read(simulatorTransitionsProvider.notifier);

    // A booted simulator keeps the section alive with nothing left to start:
    // the slimming behind the gear governs the *next* boot.
    if (startable.isEmpty && !anyBooted) return const SizedBox.shrink();

    final folds = startable.length > SimulatorList.folded;
    final shown = folds && !_showAll
        ? startable.take(SimulatorList.folded)
        : startable;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: DeviceListMetrics.sectionGap),
        DeviceSectionHeader(
          title: 'iOS simulators',
          action: DeviceSectionAction(
            key: const Key('simulator-slimming-open'),
            tooltip: 'Simulator slimming…',
            onPressed: () => SimulatorSlimmingDialog.show(context),
          ),
        ),
        if (startable.isEmpty)
          const DeviceListNote(
            'Every simulator that can start is running — they are listed '
            'above.',
          ),
        for (final simulator in shown)
          DeviceRow(
            key: Key('startable-simulator-${simulator.udid}'),
            title: simulator.name,
            // Booting is slow — ten seconds and up — and nothing else on
            // screen changes, so the row has to say so itself.
            meta: busy.contains(simulator.udid)
                ? 'starting…'
                : simulator.runtimeName,
            actions: [
              DeviceRowAction(
                key: Key('start-simulator-${simulator.udid}'),
                icon: AppIcons.playCircle,
                tooltip: 'Start ${simulator.name}',
                primary: true,
                busy: busy.contains(simulator.udid),
                onPressed: () => transitions.boot(simulator.udid),
              ),
            ],
          ),
        if (folds)
          DeviceListExpander(
            key: const Key('simulators-show-all'),
            label: _showAll ? 'Show fewer' : 'Show all (${startable.length})',
            expanded: _showAll,
            onPressed: () => setState(() => _showAll = !_showAll),
          ),
      ],
    );
  }
}
