// **What the pane offers when there is no picture** — the message, the devices
// adb can see, the AVDs that could be booted, and the simulators beside them.
//
// A part of `device_pane.dart` rather than its own library: every widget here
// is private to the pane, and keeping the names exactly as they were is what
// lets the pane's committed widget tree prove the move changed nothing.
part of 'device_pane.dart';

class _DeviceEmptyState extends ConsumerWidget {
  const _DeviceEmptyState({
    required this.message,
    required this.stopping,
    required this.booting,
    required this.onPreview,
    required this.onStopEmulator,
    required this.onBootAvd,
  });

  final String message;
  final Set<String> stopping;
  final Set<String> booting;
  final Future<void> Function(AndroidDevice device) onPreview;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;
  final Future<void> Function(String name) onBootAvd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.deviceMobile,
                size: 40,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              // Above both lists, because it governs both. It used to sit
              // inside the Emulators section, which meant a Mac with Xcode and
              // no Android SDK — where the only startable devices are iOS
              // simulators — never saw the switch that decides how they start.
              const _HeadlessDeviceToggle(),
              _DeviceList(
                stopping: stopping,
                booting: booting,
                onPreview: onPreview,
                onStopEmulator: onStopEmulator,
                onBootAvd: onBootAvd,
              ),
              // Below the Android sections, and independent of them: a Mac with
              // Xcode and no Android SDK still has simulators to start, and the
              // message above — which is about the missing SDK — must not be
              // the end of the pane there.
              const SimulatorList(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything the pane can be pointed at — the devices adb can see and the AVDs
/// that could be booted — in one list, each row offering what makes sense for
/// what it is.
///
/// The actions live **here, per row**, and not only on the toolbar. Stop in
/// particular: seeing an emulator running and having no way to shut it down
/// without first starting a video stream of it is the bug this list exists to
/// close. Starting a live view is not a prerequisite for ending a process.
///
/// Rows that cannot be used say why instead of being silently inert.
class _DeviceList extends ConsumerWidget {
  const _DeviceList({
    required this.stopping,
    required this.booting,
    required this.onPreview,
    required this.onStopEmulator,
    required this.onBootAvd,
  });

  final Set<String> stopping;
  final Set<String> booting;
  final Future<void> Function(AndroidDevice device) onPreview;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;
  final Future<void> Function(String name) onBootAvd;

  /// What a row says about itself under its name.
  static String _stateLine(AndroidDevice device) => switch (device.state) {
    DeviceConnectionState.device =>
      device.isEmulator
          ? 'running · ${device.serial}'
          : 'connected · ${device.serial}',
    DeviceConnectionState.unauthorized =>
      'not authorised — accept the USB debugging prompt on the device',
    DeviceConnectionState.offline =>
      'offline — reconnect it, or unplug and plug it back in',
    DeviceConnectionState.unknown => 'unusable · ${device.serial}',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices =
        ref.watch(devicesProvider).asData?.value ?? const <AndroidDevice>[];
    // A booted simulator is a connected device. It was listed in its own
    // section under the *idle* emulators, which put the one thing running
    // below the things that are not.
    final simulators = ref.watch(bootedSimulatorsProvider);
    final busySimulators = ref.watch(simulatorTransitionsProvider);
    final canMirror = ref.watch(simulatorBackendProvider) != null;
    final avds = ref.watch(avdsProvider).asData?.value ?? const <Avd>[];
    final runningAvdNames = {
      for (final avd in avds)
        if (avd.runningSerial != null) avd.runningSerial!: avd.name,
    };
    // AVDs that are not running are the only ones worth a Start; a running one
    // is already a row above, with its serial and its Stop.
    final idle = [
      for (final avd in avds)
        if (!avd.isRunning) avd,
    ];
    // The Emulators section exists whenever there is an emulator to start *or*
    // one to put back. Hanging it off the idle list alone hid the Slimming
    // dialog — and with it Restore, which only works on a *running* emulator —
    // in exactly the case Restore is for: the one AVD on the machine started,
    // so nothing was idle and the header that carries the button was gone.
    final anyEmulator = avds.isNotEmpty || devices.any((d) => d.isEmulator);
    if (devices.isEmpty && idle.isEmpty && simulators.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (devices.isNotEmpty || simulators.isNotEmpty) ...[
          const SizedBox(height: 16),
          const DeviceSectionHeader(title: 'Connected'),
          const SizedBox(height: 4),
          for (final simulator in simulators)
            _DeviceRow(
              key: Key('simulator-${simulator.udid}'),
              title: simulator.name,
              subtitle: switch (simulator.state) {
                SimulatorState.booting => 'starting…',
                SimulatorState.shuttingDown => 'shutting down…',
                _ => 'running · ${simulator.runtimeName}',
              },
              actions: [
                if (canMirror && simulator.state.isReady)
                  _RowAction(
                    key: Key('live-view-${simulator.udid}'),
                    label: 'Live view',
                    busy: busySimulators.contains(simulator.udid),
                    onPressed: () async => ref
                        .read(simulatorLiveViewProvider.notifier)
                        .start(simulator.udid),
                  ),
                if (simulator.state.isReady)
                  _RowAction(
                    key: Key('stop-simulator-${simulator.udid}'),
                    label: 'Stop',
                    busy: busySimulators.contains(simulator.udid),
                    onPressed: () async {
                      if (!await confirmSimulatorShutdown(
                        context,
                        simulator.name,
                      )) {
                        return;
                      }
                      await ref
                          .read(simulatorTransitionsProvider.notifier)
                          .shutdown(simulator.udid);
                    },
                  ),
              ],
            ),
          for (final device in devices)
            _DeviceRow(
              title: runningAvdNames[device.serial] ?? device.displayName,
              subtitle: _stateLine(device),
              actions: [
                if (device.isReady)
                  _RowAction(
                    key: Key('preview-${device.serial}'),
                    label: 'Live preview',
                    onPressed: () => onPreview(device),
                  ),
                // Reading the device's storage, and moving files either way.
                // Its own dialog because it is a browse rather than a verb —
                // see `DeviceFilesDialog`, which asks the driver what roots it
                // can reach rather than starting at `/`.
                if (device.isReady)
                  _RowAction(
                    key: Key('files-${device.serial}'),
                    label: 'Files',
                    onPressed: () => DeviceFilesDialog.show(context, device),
                  ),
                // Only emulators: `emu kill` talks to the emulator console, so
                // on a phone it could only ever fail.
                if (device.isReady && device.isEmulator)
                  _RowAction(
                    key: Key('stop-emulator-${device.serial}'),
                    label: 'Stop',
                    busy: stopping.contains(device.serial),
                    onPressed: () => onStopEmulator(
                      serial: device.serial,
                      label:
                          runningAvdNames[device.serial] ?? device.displayName,
                    ),
                  ),
              ],
            ),
        ],
        if (anyEmulator) ...[
          const SizedBox(height: 16),
          DeviceSectionHeader(
            title: 'Emulators',
            action: TextButton(
              key: const Key('android-slimming-open'),
              onPressed: () => AndroidSlimmingDialog.show(context),
              child: const Text('Slimming'),
            ),
          ),
          if (idle.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Every emulator is running — they are listed above.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final avd in idle)
            _DeviceRow(
              title: avd.name,
              subtitle: booting.contains(avd.name) ? 'starting…' : null,
              actions: [
                _RowAction(
                  key: Key('start-avd-${avd.name}'),
                  label: 'Start',
                  busy: booting.contains(avd.name),
                  onPressed: () => onBootAvd(avd.name),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

/// One action on a device row. A spinner replaces the label while it runs,
/// because with a headless emulator nothing else on screen changes.
class _RowAction extends StatelessWidget {
  const _RowAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.title,
    required this.subtitle,
    required this.actions,
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, overflow: TextOverflow.ellipsis),
      trailing: actions.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: actions),
    );
  }
}

/// The one switch that decides whether a started device gets a window.
///
/// Hidden when there is nothing to start: a switch about starting devices is
/// noise on a machine with none, and the empty state already says why there
/// are none.
///
/// The subtitle names both platforms because the switch means opposite
/// mechanics on each — `-no-window` for an AVD, and *not* opening
/// Simulator.app for an iOS device, which `simctl` never opens by itself.
/// What it promises the user is the same on both, so that is what it says.
class _HeadlessDeviceToggle extends ConsumerWidget {
  const _HeadlessDeviceToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idleAvds = (ref.watch(avdsProvider).asData?.value ?? const <Avd>[])
        .where((avd) => !avd.isRunning)
        .isNotEmpty;
    final startableSimulators = ref
        .watch(startableSimulatorsProvider)
        .isNotEmpty;
    if (!idleAvds && !startableSimulators) return const SizedBox.shrink();

    final both = idleAvds && startableSimulators;
    return SwitchListTile(
      key: const Key('headless-emulator-toggle'),
      dense: true,
      value: ref.watch(headlessDeviceProvider),
      onChanged: (value) =>
          ref.read(headlessDeviceProvider.notifier).update(value),
      title: const Text('Start without a window'),
      subtitle: Text(
        both
            ? 'Watch it here instead. Turn off for the emulator\'s extended '
                  'controls, or the Simulator app.'
            : startableSimulators
            ? 'Watch it here instead. Turn off to open the Simulator app too.'
            : 'Watch it here instead. Turn off for the emulator\'s own '
                  'extended controls.',
      ),
    );
  }
}
