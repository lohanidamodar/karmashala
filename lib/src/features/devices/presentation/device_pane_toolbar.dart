// **The control bar above the picture** — the one picker that lists Android
// devices and booted simulators together, the start/stop/restart buttons, the
// refresh, wireless pairing, and the power button that shuts down whichever of
// the two the bar is currently about.
//
// `confirmSimulatorShutdown` lives here and the device list calls it: a part
// shares the library's privacy, so the shared dialog needs neither a second
// copy nor a public export.
//
// A part of `device_pane.dart` rather than its own library, for the reason the
// device list gives: the type names are what the pane's committed widget tree
// records, so making them public to move them would cost the proof.
part of 'device_pane.dart';

/// Prefixes that keep an Android serial and a simulator udid apart in the one
/// picker. Both are opaque strings, and a value that could be either would make
/// the selection ambiguous the first time a serial looked like a udid.
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
    // Android devices and booted simulators in one list. They are the same
    // thing to the user — a device with a screen they want to see — and keeping
    // them apart meant a booted simulator was invisible in the picker that is
    // supposed to name what the pane is about.
    final simulators = ref.watch(bootedSimulatorsProvider);
    final chosenSimulator = ref.watch(selectedSimulatorUdidProvider);
    final simulatorState = ref.watch(simulatorLiveViewProvider);
    // The simulator whose picture is up, whatever the picker says.
    //
    // Every state but idle names one, a failed start included: that state still
    // has the pane showing something about that device, and its Stop is the
    // dismiss that clears it.
    final liveSimulator = switch (simulatorState) {
      SimulatorLiveViewIdle() => null,
      SimulatorLiveViewStarting(:final udid) => udid,
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewFailed(:final udid) => udid,
    };
    // Restarting a *start* is not offered: [SimulatorLiveViewController.start]
    // refuses to interrupt one that is already in flight, so the button would
    // be inert for exactly the twenty seconds someone is most likely to press
    // it. A running picture and a failed one can both be started over.
    final restartableSimulator = switch (simulatorState) {
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewFailed(:final udid) => udid,
      _ => null,
    };
    // The simulator this toolbar is *about*, when no live view settles it.
    //
    // Deliberately keyed on [selectedDeviceSerialProvider] — the explicit
    // Android choice — and not on [selected], which is the derived one. Its
    // convenience default answers "the only ready device" even when nobody has
    // chosen anything, so on any machine with one phone plugged in or one
    // emulator running it was never null, the old `selected == null` guard was
    // never true, and every control below stayed wired to Android: picking a
    // simulator here snapped the picker straight back to the phone, and the
    // Stop pressed while looking at the simulator's picture went to the
    // Android stream — or nowhere — leaving the picture up. That is the
    // reported fault. The picker clears one selection when it sets the other,
    // so the two explicit choices can never both be set.
    final chosenAndroid = ref.watch(selectedDeviceSerialProvider);
    final pickedSimulator =
        chosenAndroid == null &&
            chosenSimulator != null &&
            simulators.any((s) => s.udid == chosenSimulator)
        ? chosenSimulator
        : null;
    // What the power button acts on, by the same rule as the rest of the bar:
    // a simulator on screen or picked wins, and only then the Android device —
    // and that one has to be an *emulator*, since `adb emu kill` talks to the
    // emulator console and could only ever fail on a handset.
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
              // `DropdownButton` is Material 2, and the app's
              // `dropdownMenuTheme` reaches only Material 3's `DropdownMenu` —
              // so this control quietly fell back to Material's own defaults
              // and came out at ~16 px with a 24 px chevron, against chrome
              // that is `bodySmall` with a `Chrome.icon` glyph. That size is
              // what made "CPH1989 (F6IZLV6LMFT4U4ZT)" wrap onto two lines,
              // not the serial: at `bodySmall` the whole label fits, and the
              // serial earns its place here because it is what tells two
              // identical handsets apart in the picker itself. The ellipsis is
              // the backstop for a pane narrow enough that it still cannot.
              child: DropdownButton<String>(
                isExpanded: true,
                isDense: true,
                style: theme.textTheme.bodySmall,
                iconSize: Chrome.icon,
                // The simulator is tested first, because when one is picked it
                // is the answer: [selected] may still be the convenience
                // default for a device nobody chose.
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
                // Picking a device here moves the live view with it: the pane is
                // about one device at a time, and the picture follows the picker
                // rather than staying on whatever was streaming first.
                //
                // Picking one kind clears the other, so the picker always shows
                // exactly what the pane is about rather than two selections
                // disagreeing about it.
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
                    // …and take the simulator's picture down with it. The pane
                    // gives that picture priority over everything else while it
                    // is up, so merely deselecting the simulator would leave an
                    // iPhone on screen with the picker naming an Android device
                    // above it. The Android half of this promise is already
                    // kept, from the other direction, by `_onSelectionChanged`.
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
          // Beside Refresh because both are about the *list* rather than about
          // one device, and only shown when there is an adb to pair with —
          // a button that could not work is worse than no button.
          if (ref.watch(adbServiceProvider) != null)
            IconButton(
              key: const Key('wireless-pairing-open'),
              tooltip: 'Pair a device over Wi-Fi',
              icon: const Icon(AppIcons.wifiHigh),
              onPressed: () => WirelessPairingDialog.show(context),
            ),
          IconButton(
            // Named for what it does. It used to say "Refresh devices", which
            // is what people pressed when the picture froze — and it refreshed
            // the list, not the stream, so nothing happened.
            tooltip: 'Refresh device list',
            icon: const Icon(AppIcons.arrowsClockwise),
            onPressed: () {
              ref.invalidate(devicesProvider);
              ref.invalidate(avdsProvider);
              ref.invalidate(iosSimulatorsProvider);
            },
          ),
          // Restart belongs to whichever live view is up. [onRestart] is
          // supplied only by the Android path, so a frozen simulator picture
          // had no way back short of Stop followed by Live view — on the one
          // platform where starting it again costs twenty seconds of
          // WebDriverAgent bootstrap.
          if (restartableSimulator != null)
            IconButton(
              tooltip: 'Restart live view',
              icon: const Icon(AppIcons.arrowCounterClockwise),
              // `start` tears the current view down before it builds the next,
              // which is the whole of a restart here: the runner inside the
              // simulator holds :8100 and :9100, so a second view cannot come
              // up beside the first anyway.
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
          // Power acts on the device this toolbar is *about*, which is the
          // same ordered answer every other control here uses. It used to be
          // supplied from [selected] alone, so while a simulator's picture was
          // up — with one Android emulator running — the button was still
          // bound to the emulator, and pressing it shut down a device the user
          // was not looking at. Stopping the wrong machine is the worst thing
          // a control on this bar can do, so it names its target and shuts
          // down nothing else.
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
          // Ordered by what is *running*, then by what is picked — never the
          // other way round. The pane below gives the simulator's picture
          // priority over every Android branch while it is up, so the Stop
          // beside the picker has to mean the thing the user is looking at.
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

/// Which device the toolbar's power button would shut down.
///
/// A sealed pair rather than a nullable udid beside a nullable serial: the two
/// cases take different verbs — `simctl shutdown` against a udid, `adb emu
/// kill` against an emulator's console — and the bug this replaced came from
/// deciding which to use by testing one nullable field against another.
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

/// Confirms before shutting a simulator down, the way stopping an emulator
/// already did.
///
/// The same act with the same cost — a running machine ends and anything on it
/// goes with it, including the picture the user is looking at — and it was
/// reachable from the row and from the toolbar without a word of warning.
/// A file-level function because both of those live in different widgets and
/// the question they ask has to be the same one.
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
