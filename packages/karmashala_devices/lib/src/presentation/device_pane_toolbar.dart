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

  /// Below this width (at 1x text) the stream action gives up its label: in a
  /// 240px side panel "Live view" beside four buttons left the picker 0px.
  static const compactBelow = 400.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Android devices and booted simulators in one list: they are the same
    // thing to the user, and apart, a booted simulator was invisible here.
    final simulators = ref.watch(bootedSimulatorsProvider);
    final model = DeviceToolbarModel.from(
      bootedSimulators: simulators,
      simulatorState: ref.watch(simulatorLiveViewProvider),
      chosenSimulator: ref.watch(selectedSimulatorUdidProvider),
      chosenAndroid: ref.watch(selectedDeviceSerialProvider),
      selected: selected,
      canStopEmulator: onStopEmulator != null,
      stoppingEmulator: stoppingEmulator,
      busySimulators: ref.watch(simulatorTransitionsProvider),
      starting: starting,
      streaming: streaming,
    );
    final picked = model.pickedSimulator;
    final restartableSimulator = model.restartableSimulator;
    final powerTarget = model.powerTarget;

    // Without a backend a simulator can still be listed, started and stopped;
    // only the picture is unavailable.
    final canMirror = ref.watch(simulatorBackendProvider) != null;
    final simulatorLive = ref.read(simulatorLiveViewProvider.notifier);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth <
            WidthClass.scaleBreakpoint(
              compactBelow,
              MediaQuery.textScalerOf(context),
            );
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: _DevicePicker(
                  // The simulator is tested first: when one is picked it is
                  // the answer, and [selected] may be a default nobody chose.
                  value: picked != null
                      ? '$_simulatorValue$picked'
                      : selected != null
                      ? '$_androidValue${selected!.serial}'
                      : null,
                  devices: devices,
                  simulators: simulators,
                  // Picking a device moves the live view with it, and picking
                  // one kind clears the other so the two cannot disagree.
                  onChanged: (value) {
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
                      unawaited(simulatorLive.stop());
                      ref
                          .read(selectedDeviceSerialProvider.notifier)
                          .select(value.substring(_androidValue.length));
                    }
                  },
                ),
              ),
              const SizedBox(width: Insets.sm),
              // Beside Refresh because both are about the *list*, and only
              // when there is an adb to pair with — an inert button is worse
              // than none.
              if (ref.watch(adbServiceProvider) != null)
                IconButton(
                  key: const Key('wireless-pairing-open'),
                  tooltip: 'Pair a device over Wi-Fi',
                  icon: const Icon(AppIcons.wifiHigh),
                  onPressed: () => WirelessPairingDialog.show(context),
                ),
              IconButton(
                // Named for what it does: "Refresh devices" is what people
                // pressed when the picture froze, and it refreshes the list.
                tooltip: 'Refresh device list',
                icon: const Icon(AppIcons.arrowsClockwise),
                onPressed: () {
                  ref.invalidate(devicesProvider);
                  ref.invalidate(avdsProvider);
                  ref.invalidate(iosSimulatorsProvider);
                },
              ),
              // Restart belongs to whichever live view is up; [onRestart] is
              // the Android path only, and a simulator costs 20 s to start.
              if (restartableSimulator != null)
                IconButton(
                  tooltip: 'Restart live view',
                  icon: const Icon(AppIcons.arrowClockwise),
                  // `start` tears the current view down first — the runner
                  // holds :8100 and :9100, so a second cannot come up beside.
                  onPressed: () => simulatorLive.start(restartableSimulator),
                )
              else if (onRestart != null)
                IconButton(
                  tooltip: 'Restart live view',
                  icon: const Icon(AppIcons.arrowClockwise),
                  onPressed: onRestart,
                ),
              // Power acts on the device this toolbar is *about* — from
              // [selected] alone it once shut down an emulator nobody watched.
              if (powerTarget != null)
                _PowerButton(
                  target: powerTarget,
                  busy: model.powerBusy,
                  onPressed: switch (powerTarget) {
                    SimulatorPowerTarget(:final udid, :final name) => () async {
                      if (!await confirmSimulatorShutdown(context, name)) {
                        return;
                      }
                      await ref
                          .read(simulatorTransitionsProvider.notifier)
                          .shutdown(udid);
                    },
                    AndroidPowerTarget() => onStopEmulator,
                  },
                ),
              _PrimaryStreamAction(
                kind: model.primary,
                compact: compact,
                onPressed: switch (model.primary) {
                  PrimaryStreamKind.starting => null,
                  PrimaryStreamKind.stopSimulator => simulatorLive.stop,
                  PrimaryStreamKind.startSimulator =>
                    canMirror ? () => simulatorLive.start(picked!) : null,
                  PrimaryStreamKind.stopAndroid => onStop,
                  PrimaryStreamKind.startAndroid => onStart,
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The one picker over Android devices and booted simulators, keyed by the
/// prefixed values above.
class _DevicePicker extends StatelessWidget {
  const _DevicePicker({
    required this.value,
    required this.devices,
    required this.simulators,
    required this.onChanged,
  });

  final String? value;
  final List<AndroidDevice> devices;
  final List<IosSimulator> simulators;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropdownButtonHideUnderline(
      // `DropdownButton` is Material 2 and the app's `dropdownMenuTheme` is
      // Material 3, so size is set here by hand.
      child: DropdownButton<String>(
        isExpanded: true,
        isDense: true,
        style: theme.textTheme.bodySmall,
        iconSize: Chrome.icon,
        value: value,
        hint: Text(
          'No device selected',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      ),
    );
  }
}

/// Shuts down what [target] names, with a spinner in its place while it goes.
class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.target,
    required this.busy,
    required this.onPressed,
  });

  final DevicePowerTarget target;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: switch (target) {
      SimulatorPowerTarget(:final name) => 'Shut down $name',
      AndroidPowerTarget(:final name) => 'Stop $name',
    },
    icon: busy
        ? const InlineSpinner(size: InlineSpinnerSize.medium)
        : const Icon(AppIcons.power),
    onPressed: busy ? null : onPressed,
  );
}

/// Start or Stop for whichever live view the toolbar is about. Labelled while
/// there is room; a glyph with the label as its tooltip when there is not.
class _PrimaryStreamAction extends StatelessWidget {
  const _PrimaryStreamAction({
    required this.kind,
    required this.compact,
    required this.onPressed,
  });

  final PrimaryStreamKind kind;
  final bool compact;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (kind == PrimaryStreamKind.starting) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
        child: InlineSpinner(
          size: InlineSpinnerSize.medium,
          semanticsLabel: kind.label,
        ),
      );
    }
    // The eye is the live view itself — play/stop were already Launch app,
    // logcat and recording, and icon-only nothing told them apart.
    final icon = Icon(kind.stops ? AppIcons.eyeSlash : AppIcons.eye);
    if (compact) {
      return IconButton(
        tooltip: kind.tooltip,
        icon: icon,
        onPressed: onPressed,
      );
    }
    return TextButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(kind.label),
    );
  }
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
