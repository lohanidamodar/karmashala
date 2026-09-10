// The control bar above the picture, and the one picker that lists Android
// devices and booted simulators together. A part, so it shares the privacy.
part of 'device_pane.dart';

/// Prefixes that keep an Android serial and a simulator udid apart in the one
/// picker: both are opaque, and a serial that looked like a udid would be lost.
const String _androidValue = 'android:';
const String _simulatorValue = 'simulator:';

class _DeviceToolbar extends ConsumerWidget {
  const _DeviceToolbar({
    required this.devices,
    required this.selected,
    required this.streaming,
    required this.starting,
    required this.stoppingEmulator,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onStopEmulator,
  });

  final List<AndroidDevice> devices;
  final AndroidDevice? selected;
  final bool streaming;
  final bool starting;
  final bool stoppingEmulator;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onRestart;
  final VoidCallback? onStopEmulator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Android devices and booted simulators in one list: they are the same
    // thing to the user, and apart, a booted simulator was invisible here.
    final simulators = ref.watch(bootedSimulatorsProvider);
    final chosenSimulator = ref.watch(selectedSimulatorUdidProvider);
    final simulatorState = ref.watch(simulatorLiveViewProvider);
    // The simulator whose picture is up, whatever the picker says — every
    // state but idle names one, a failed start included, whose Stop dismisses.
    final liveSimulator = switch (simulatorState) {
      SimulatorLiveViewIdle() => null,
      SimulatorLiveViewStarting(:final udid) => udid,
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewFailed(:final udid) => udid,
    };
    // Restarting a *start* is not offered: [SimulatorLiveViewController.start]
    // refuses to interrupt one in flight, so it would be inert for 20 seconds.
    final restartableSimulator = switch (simulatorState) {
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewFailed(:final udid) => udid,
      _ => null,
    };
    // The simulator this toolbar is *about* when no live view settles it.
    // Keyed on the explicit choice: the derived one is never null with a phone.
    final chosenAndroid = ref.watch(selectedDeviceSerialProvider);
    final pickedSimulator =
        chosenAndroid == null &&
            chosenSimulator != null &&
            simulators.any((s) => s.udid == chosenSimulator)
        ? chosenSimulator
        : null;
    // What the power button acts on: a simulator on screen or picked wins,
    // then an Android *emulator* — `adb emu kill` could only fail on a phone.
    final liveOrPicked = liveSimulator ?? pickedSimulator;
    final _PowerTarget? powerTarget = switch ((liveOrPicked, selected)) {
      (final String udid, _) => _SimulatorPower(
        udid,
        simulators
                .where((s) => s.udid == udid)
                .map((s) => s.name)
                .firstOrNull ??
            'this simulator',
      ),
      (null, final AndroidDevice device)
          when device.isEmulator && onStopEmulator != null =>
        _AndroidPower(device.displayName),
      _ => null,
    };
    final busySimulators = ref.watch(simulatorTransitionsProvider);

    // Without a backend a simulator can still be listed, started and stopped;
    // only the picture is unavailable.
    final canMirror = ref.watch(simulatorBackendProvider) != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              // `DropdownButton` is Material 2 and the app's
              // `dropdownMenuTheme` is Material 3, so size is set here by hand.
              child: DropdownButton<String>(
                isExpanded: true,
                isDense: true,
                style: theme.textTheme.bodySmall,
                iconSize: Chrome.icon,
                // The simulator is tested first: when one is picked it is the
                // answer, and [selected] may be a default nobody chose.
                value: pickedSimulator != null
                    ? '$_simulatorValue$pickedSimulator'
                    : selected != null
                    ? '$_androidValue${selected!.serial}'
                    : null,
                hint: Text(
                  'No device selected',
                  style: theme.textTheme.bodySmall,
                ),
                items: [
                  for (final device in devices)
                    DropdownMenuItem(
                      value: '$_androidValue${device.serial}',
                      enabled: device.isReady,
                      child: Text(
                        device.isReady
                            ? '${device.displayName} (${device.serial})'
                            : '${device.displayName} — ${device.state.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  for (final simulator in simulators)
                    DropdownMenuItem(
                      value: '$_simulatorValue${simulator.udid}',
                      child: Text(
                        simulator.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                // Picking a device moves the live view with it, and picking
                // one kind clears the other so the two cannot disagree.
                onChanged: (value) {
                  if (value == null) return;
                  if (value.startsWith(_simulatorValue)) {
                    ref
                        .read(selectedDeviceSerialProvider.notifier)
                        .select(null);
                    ref
                        .read(selectedSimulatorUdidProvider.notifier)
                        .select(value.substring(_simulatorValue.length));
                  } else {
                    ref
                        .read(selectedSimulatorUdidProvider.notifier)
                        .select(null);
                    // …and take the simulator's picture down: the pane gives
                    // it priority, so deselecting alone would leave it up.
                    unawaited(
                      ref.read(simulatorLiveViewProvider.notifier).stop(),
                    );
                    ref
                        .read(selectedDeviceSerialProvider.notifier)
                        .select(value.substring(_androidValue.length));
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Beside Refresh because both are about the *list*, and only when
          // there is an adb to pair with — an inert button is worse than none.
          if (ref.watch(adbServiceProvider) != null)
            IconButton(
              key: const Key('wireless-pairing-open'),
              tooltip: 'Pair a device over Wi-Fi',
              icon: const Icon(AppIcons.wifiHigh),
              onPressed: () => WirelessPairingDialog.show(context),
            ),
          IconButton(
            // Named for what it does: "Refresh devices" is what people pressed
            // when the picture froze, and it refreshes the list, not the stream.
            tooltip: 'Refresh device list',
            icon: const Icon(AppIcons.arrowsClockwise),
            onPressed: () {
              ref.invalidate(devicesProvider);
              ref.invalidate(avdsProvider);
              ref.invalidate(iosSimulatorsProvider);
            },
          ),
          // Restart belongs to whichever live view is up; [onRestart] is the
          // Android path only, and a simulator costs 20 s to start again.
          if (restartableSimulator != null)
            IconButton(
              tooltip: 'Restart live view',
              icon: const Icon(AppIcons.arrowCounterClockwise),
              // `start` tears the current view down first — the runner holds
              // :8100 and :9100, so a second cannot come up beside it.
              onPressed: () => ref
                  .read(simulatorLiveViewProvider.notifier)
                  .start(restartableSimulator),
            )
          else if (onRestart != null)
            IconButton(
              tooltip: 'Restart live view',
              icon: const Icon(AppIcons.arrowCounterClockwise),
              onPressed: onRestart,
            ),
          // Power acts on the device this toolbar is *about* — from [selected]
          // alone it once shut down an emulator nobody was looking at.
          if (powerTarget != null)
            IconButton(
              tooltip: switch (powerTarget) {
                _SimulatorPower(:final name) => 'Shut down $name',
                _AndroidPower(:final name) => 'Stop $name',
              },
              icon: stoppingEmulator || busySimulators.contains(liveOrPicked)
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.power),
              onPressed:
                  stoppingEmulator || busySimulators.contains(liveOrPicked)
                  ? null
                  : switch (powerTarget) {
                      _SimulatorPower(:final udid, :final name) => () async {
                        if (!await confirmSimulatorShutdown(context, name)) {
                          return;
                        }
                        await ref
                            .read(simulatorTransitionsProvider.notifier)
                            .shutdown(udid);
                      },
                      _AndroidPower() => onStopEmulator,
                    },
            ),
          if (starting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          // Ordered by what is *running*, then by what is picked: the pane
          // gives the simulator's picture priority, so Stop means what is up.
          else if (liveSimulator != null)
            TextButton.icon(
              onPressed: () =>
                  ref.read(simulatorLiveViewProvider.notifier).stop(),
              icon: const Icon(AppIcons.stop),
              label: const Text('Stop'),
            )
          else if (pickedSimulator != null)
            TextButton.icon(
              onPressed: canMirror
                  ? () => ref
                        .read(simulatorLiveViewProvider.notifier)
                        .start(pickedSimulator)
                  : null,
              icon: const Icon(AppIcons.play),
              label: const Text('Live view'),
            )
          else if (streaming)
            TextButton.icon(
              onPressed: onStop,
              icon: const Icon(AppIcons.stop),
              label: const Text('Stop'),
            )
          else
            TextButton.icon(
              onPressed: onStart,
              icon: const Icon(AppIcons.play),
              label: const Text('Live view'),
            ),
        ],
      ),
    );
  }
}

/// Which device the toolbar's power button would shut down. A sealed pair, not
/// two nullables: `simctl shutdown` and `adb emu kill` are different verbs.
sealed class _PowerTarget {
  const _PowerTarget(this.name);

  /// What the tooltip calls it, so the button says what it will stop.
  final String name;
}

class _SimulatorPower extends _PowerTarget {
  const _SimulatorPower(this.udid, super.name);
  final String udid;
}

class _AndroidPower extends _PowerTarget {
  const _AndroidPower(super.name);
}

/// Confirms before shutting a simulator down: a running machine ends and the
/// picture goes with it. File-level because the row and the toolbar both ask.
Future<bool> confirmSimulatorShutdown(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Shut down $name?'),
      content: const Text(
        'The simulator will shut down. Anything running on it ends, and its '
        'live view closes with it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Shut down'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
