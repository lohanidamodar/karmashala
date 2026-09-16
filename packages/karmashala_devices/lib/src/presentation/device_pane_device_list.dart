// What the pane offers when there is no picture: the message, the devices,
// the AVDs, the simulators. A part, so the committed tree still matches.
part of 'device_pane.dart';

/// What the rows of the device list can do, and which of them are mid-way:
/// built once by the pane and handed down, rather than five parameters
/// threaded through every widget between the pane and a row.
class _DeviceListActions {
  const _DeviceListActions({
    required this.stopping,
    required this.booting,
    required this.onPreview,
    required this.onStopEmulator,
    required this.onBootAvd,
  });

  /// Emulators with a shutdown in flight, by serial.
  final Set<String> stopping;

  /// AVDs with a boot in flight, by name.
  final Set<String> booting;

  final Future<void> Function(AndroidDevice device) onPreview;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;
  final Future<void> Function(String name) onBootAvd;
}

class _DeviceEmptyState extends ConsumerWidget {
  const _DeviceEmptyState({required this.message, required this.actions});

  final String message;
  final _DeviceListActions actions;

  /// The widest the message and the lists get: rows of a name and three
  /// actions, not a paragraph of prose.
  static const maxWidth = 460.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Unbounded here, so it draws without a scroll view of its own:
              // this one scrolls the message and the lists together.
              PanePlaceholder(icon: AppIcons.deviceMobile, message: message),
              // Above both lists, because it governs both: inside Emulators,
              // a Mac with Xcode and no Android SDK never saw it.
              const _HeadlessDeviceToggle(),
              _DeviceList(actions: actions),
              // Below the Android sections and independent of them: a Mac
              // with no SDK still has simulators to start.
              const SimulatorList(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything the pane can be pointed at — connected devices and bootable
/// AVDs — acting per row: stopping an emulator must not need a live view.
class _DeviceList extends ConsumerWidget {
  const _DeviceList({required this.actions});

  final _DeviceListActions actions;

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
    // A booted simulator is a connected device: in its own section under the
    // *idle* emulators, the one thing running sat below the ones that are not.
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
    // The Emulators section exists whenever there is one to start *or* one to
    // put back: off the idle list alone, it hid Restore exactly when it was due.
    final anyEmulator = avds.isNotEmpty || devices.any((d) => d.isEmulator);
    if (devices.isEmpty && idle.isEmpty && simulators.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (devices.isNotEmpty || simulators.isNotEmpty) ...[
          const SizedBox(height: Insets.lg),
          const DeviceSectionHeader(title: 'Connected'),
          const SizedBox(height: Insets.xs),
          for (final simulator in simulators)
            DeviceActionRow(
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
            DeviceActionRow(
              title: runningAvdNames[device.serial] ?? device.displayName,
              subtitle: _stateLine(device),
              actions: [
                if (device.isReady)
                  _RowAction(
                    key: Key('preview-${device.serial}'),
                    label: 'Live preview',
                    onPressed: () => actions.onPreview(device),
                  ),
                // Reading the device's storage, and moving files either way.
                // Its own dialog; it asks the driver which roots it can reach.
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
                    busy: actions.stopping.contains(device.serial),
                    onPressed: () => actions.onStopEmulator(
                      serial: device.serial,
                      label:
                          runningAvdNames[device.serial] ?? device.displayName,
                    ),
                  ),
              ],
            ),
        ],
        if (anyEmulator) ...[
          const SizedBox(height: Insets.lg),
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
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.xs,
                Insets.lg,
                0,
              ),
              child: Text(
                'Every emulator is running — they are listed above.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final avd in idle)
            DeviceActionRow(
              title: avd.name,
              subtitle: actions.booting.contains(avd.name)
                  ? 'starting…'
                  : null,
              actions: [
                _RowAction(
                  key: Key('start-avd-${avd.name}'),
                  label: 'Start',
                  busy: actions.booting.contains(avd.name),
                  onPressed: () => actions.onBootAvd(avd.name),
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
          ? InlineSpinner(
              size: InlineSpinnerSize.medium,
              semanticsLabel: label,
            )
          : Text(label),
    );
  }
}

/// The one switch that decides whether a started device gets a window. Hidden
/// with nothing to start, and worded by promise: the mechanics differ per OS.
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
