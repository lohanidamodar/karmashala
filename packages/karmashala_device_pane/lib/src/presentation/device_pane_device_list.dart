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
  const _DeviceEmptyState({
    required this.message,
    required this.actions,
    this.failed = false,
  });

  final String message;
  final _DeviceListActions actions;

  /// Whether [message] reports something that went wrong, rather than that
  /// nothing is here yet: a warning in the failure colour, not a phone.
  final bool failed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anything =
        (ref.watch(devicesProvider).asData?.value.isNotEmpty ?? false) ||
        (ref.watch(avdsProvider).asData?.value.isNotEmpty ?? false) ||
        (ref.watch(hostCanRunSimulatorsProvider) &&
            (ref.watch(startableSimulatorsProvider).isNotEmpty ||
                ref.watch(bootedSimulatorsProvider).isNotEmpty));
    // With nothing to list the message is the whole pane, centred as every
    // other empty pane is.
    final icon = failed ? AppIcons.warning : AppIcons.deviceMobile;
    final iconColor = failed ? Theme.of(context).colorScheme.error : null;
    if (!anything) {
      return PanePlaceholder(
        icon: icon,
        iconColor: iconColor,
        message: message,
      );
    }
    // With a list under it the column starts at the top: centred, every row
    // moved each time a device came or went.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: DeviceListMetrics.maxWidth),
        child: SingleChildScrollView(
          primary: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // One line, not a hero: the lists under it are the pane.
              PanePlaceholder.inline(
                icon: icon,
                iconColor: iconColor,
                message: message,
              ),
              _DeviceList(actions: actions),
              // Below the Android sections and independent of them: a Mac
              // with no SDK still has simulators to start.
              const SimulatorList(),
              // Under both lists, because it governs both: inside Emulators,
              // a Mac with Xcode and no Android SDK never saw it.
              const DeviceStartOptions(),
              const SizedBox(height: Insets.md),
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (devices.isNotEmpty || simulators.isNotEmpty) ...[
          const SizedBox(height: DeviceListMetrics.sectionGap),
          const DeviceSectionHeader(title: 'Connected'),
          for (final simulator in simulators)
            DeviceRow(
              key: Key('simulator-${simulator.udid}'),
              title: simulator.name,
              subtitle: switch (simulator.state) {
                SimulatorState.booting => 'starting…',
                SimulatorState.shuttingDown => 'shutting down…',
                _ => 'running · ${simulator.runtimeName}',
              },
              actions: [
                if (canMirror && simulator.state.isReady)
                  DeviceRowAction(
                    key: Key('live-view-${simulator.udid}'),
                    icon: AppIcons.eye,
                    tooltip: _liveView,
                    busy: busySimulators.contains(simulator.udid),
                    onPressed: () async => ref
                        .read(simulatorLiveViewProvider.notifier)
                        .start(simulator.udid),
                  ),
                if (simulator.state.isReady)
                  DeviceRowAction(
                    key: Key('stop-simulator-${simulator.udid}'),
                    icon: AppIcons.power,
                    // The toolbar's words for the toolbar's glyph.
                    tooltip: 'Shut down ${simulator.name}',
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
            DeviceRow(
              title: runningAvdNames[device.serial] ?? device.displayName,
              subtitle: _stateLine(device),
              actions: [
                if (device.isReady)
                  DeviceRowAction(
                    key: Key('preview-${device.serial}'),
                    icon: AppIcons.eye,
                    tooltip: _liveView,
                    onPressed: () => actions.onPreview(device),
                  ),
                // Reading the device's storage, and moving files either way.
                // Its own dialog; it asks the driver which roots it can reach.
                if (device.isReady)
                  DeviceRowAction(
                    key: Key('files-${device.serial}'),
                    icon: AppIcons.folder,
                    tooltip: 'Files',
                    onPressed: () => DeviceFilesDialog.show(context, device),
                  ),
                // Install, launch, stop — on this row's device, whichever one
                // a preview is showing.
                if (device.isReady)
                  DeviceRowAction(
                    key: Key('apps-${device.serial}'),
                    icon: AppIcons.package,
                    tooltip: 'Install or launch an app',
                    onPressed: () => DeviceAppsDialog.show(context, device),
                  ),
                // Only emulators: `emu kill` talks to the emulator console, so
                // on a phone it could only ever fail.
                if (device.isReady && device.isEmulator)
                  DeviceRowAction(
                    key: Key('stop-emulator-${device.serial}'),
                    icon: AppIcons.power,
                    tooltip:
                        'Stop '
                        '${runningAvdNames[device.serial] ?? device.displayName}',
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
          const SizedBox(height: DeviceListMetrics.sectionGap),
          DeviceSectionHeader(
            title: 'Android emulators',
            action: DeviceSectionAction(
              key: const Key('android-slimming-open'),
              tooltip: 'Emulator slimming…',
              onPressed: () => AndroidSlimmingDialog.show(context),
            ),
          ),
          if (idle.isEmpty)
            const DeviceListNote(
              'Every emulator is running — they are listed above.',
            ),
          for (final avd in idle)
            DeviceRow(
              title: avd.name,
              subtitle: actions.booting.contains(avd.name) ? 'starting…' : null,
              actions: [
                DeviceRowAction(
                  key: Key('start-avd-${avd.name}'),
                  icon: AppIcons.playCircle,
                  tooltip: 'Start ${avd.name}',
                  primary: true,
                  busy: actions.booting.contains(avd.name),
                  onPressed: () => actions.onBootAvd(avd.name),
                ),
              ],
            ),
        ],
      ],
    );
  }

  /// The toolbar's word for the toolbar's glyph.
  static const _liveView = 'Live view';
}
