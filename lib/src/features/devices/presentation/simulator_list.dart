import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/ios_device_providers.dart';
import '../application/simulator_live_view.dart';
import '../domain/ios_simulator.dart';

/// The iOS Simulators section of the device sidebar.
///
/// A **picker plus a Start button**, not a list of every simulator. Xcode
/// accumulates them: this developer's machine holds 170, of which 124 have no
/// installed runtime and 46 can actually be started. Listing all of them would
/// bury the Android devices above and give a user 170 rows to read to find the
/// iPhone they meant.
///
/// Booted simulators *are* listed, because there are rarely more than one or
/// two and each is something you might want to act on.
///
/// The whole section disappears off macOS rather than showing an empty state.
/// Windows and Linux cannot have simulators at all, and a permanently empty
/// "iOS Simulators" heading is a question the user cannot answer.
class SimulatorList extends ConsumerStatefulWidget {
  const SimulatorList({super.key});

  @override
  ConsumerState<SimulatorList> createState() => _SimulatorListState();
}

class _SimulatorListState extends ConsumerState<SimulatorList> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(hostCanRunSimulatorsProvider)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final booted = ref.watch(bootedSimulatorsProvider);
    final startable = ref.watch(startableSimulatorsProvider);
    final busy = ref.watch(simulatorTransitionsProvider);
    final transitions = ref.read(simulatorTransitionsProvider.notifier);

    if (booted.isEmpty && startable.isEmpty) return const SizedBox.shrink();

    // A simulator that was picked and has since started is no longer in the
    // list it was picked from; falling back keeps the picker on something real
    // rather than showing a blank selection.
    final picked = startable.any((s) => s.udid == _picked)
        ? _picked
        : (startable.isEmpty ? null : startable.first.udid);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('iOS Simulators', style: theme.textTheme.labelLarge),
        ),
        for (final simulator in booted)
          _SimulatorRow(
            key: Key('simulator-${simulator.udid}'),
            simulator: simulator,
            busy: busy.contains(simulator.udid),
            // Only offered when there is a backend to mirror with. Without
            // WebDriverAgent a simulator can still be started and stopped, and
            // a Live view button that always failed would be worse than none.
            onLiveView: ref.watch(simulatorBackendProvider) == null
                ? null
                : () => ref
                      .read(simulatorLiveViewProvider.notifier)
                      .start(simulator.udid),
            onStop: () => transitions.shutdown(simulator.udid),
          ),
        if (startable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: const Key('simulator-picker'),
                    initialValue: picked,
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final simulator in startable)
                        DropdownMenuItem(
                          value: simulator.udid,
                          child: Text(
                            simulator.displayName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => _picked = value),
                  ),
                ),
                const SizedBox(width: 8),
                _StartButton(
                  // Booting is slow — ten seconds and up — and nothing else on
                  // screen changes while it happens, so the button has to say
                  // so itself.
                  busy: picked != null && busy.contains(picked),
                  onPressed: picked == null
                      ? null
                      : () => transitions.boot(picked),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SimulatorRow extends StatelessWidget {
  const _SimulatorRow({
    super.key,
    required this.simulator,
    required this.busy,
    required this.onStop,
    this.onLiveView,
  });

  final IosSimulator simulator;
  final bool busy;
  final VoidCallback onStop;
  final VoidCallback? onLiveView;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      title: Text(simulator.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        switch (simulator.state) {
          SimulatorState.booted => 'running · ${simulator.runtimeName}',
          SimulatorState.booting => 'starting…',
          SimulatorState.shuttingDown => 'shutting down…',
          _ => simulator.runtimeName,
        },
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onLiveView != null && simulator.state.isReady)
            TextButton(
              key: Key('live-view-${simulator.udid}'),
              onPressed: busy ? null : onLiveView,
              child: const Text('Live view'),
            ),
          TextButton(
            key: Key('stop-simulator-${simulator.udid}'),
            onPressed: busy || !simulator.state.isReady ? null : onStop,
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Stop'),
          ),
        ],
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      key: const Key('start-simulator'),
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Start'),
    );
  }
}
