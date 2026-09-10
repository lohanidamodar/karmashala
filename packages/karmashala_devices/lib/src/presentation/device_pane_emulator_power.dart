// Booting an AVD and shutting an emulator down, with the in-flight serials
// the rows read. `on _DeviceLiveStream`: a stop must take the picture down.
part of 'device_pane.dart';

mixin _DeviceEmulatorPower on _DeviceLiveStream {
  /// Emulators with a shutdown in flight, by serial — one per row, because the
  /// list can offer to stop more than one.
  final Set<String> _stopping = <String>{};

  /// AVDs with a boot in flight, by AVD name. Headless there is nothing to
  /// watch, so the row has to say it is starting or the click looks ignored.
  final Set<String> _booting = <String>{};

  /// Boots an AVD and opens the live view on it — one flow, since with
  /// `-no-window` the live view is the only way to see what just started.
  Future<void> _bootAvd(String name) async {
    final adb = ref.read(adbServiceProvider);
    if (adb == null || _booting.contains(name)) return;
    setState(() => _booting.add(name));
    String? serial;
    String? failure;
    try {
      serial = await adb.bootAvdAndWait(
        name,
        headless: ref.read(headlessDeviceProvider),
        extraArguments: ref.read(androidEmulatorArgumentsProvider),
      );
      // After the wait, never before: `settings put` and `pm disable-user`
      // need a running package manager. A started emulator beats a slim one.
      await ref.read(androidSlimmingProvider.notifier).applyAfterBoot(serial);
    } catch (error) {
      failure = '$error';
    }
    if (!mounted) return;
    setState(() => _booting.remove(name));
    ref.invalidate(devicesProvider);
    ref.invalidate(avdsProvider);
    if (failure != null || serial == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(failure ?? '$name did not start.')),
      );
      return;
    }
    // Wait for the refreshed list rather than reading the stale one: the device
    // that was just booted is precisely the one not in it yet.
    final devices = await ref.read(devicesProvider.future);
    final device = devices.where((d) => d.serial == serial).firstOrNull;
    if (!mounted || device == null || !device.isReady) return;
    await _startStream(device);
  }

  Future<void> _stopEmulator({
    required String serial,
    required String label,
  }) async {
    final adb = ref.read(adbServiceProvider);
    if (adb == null || _stopping.contains(serial)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop $label?'),
        content: const Text(
          'The emulator will shut down. Anything it has not written to a '
          'snapshot is lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop emulator'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _stopping.add(serial));
    // Take the stream down first: killing the emulator underneath a live view
    // leaves a frozen picture that reads as a new fault.
    if (_liveSerial == serial) await _stopStream();
    String? failure;
    try {
      final stopped = await adb.stopEmulator(serial);
      if (!stopped) {
        failure = '$label did not exit.';
      }
    } catch (error) {
      failure = '$error';
    }
    if (!mounted) return;
    setState(() => _stopping.remove(serial));
    if (failure == null && ref.read(selectedDeviceSerialProvider) == serial) {
      // Leaving the dead serial selected would pin the picker to a device that
      // no longer exists.
      ref.read(selectedDeviceSerialProvider.notifier).select(null);
    }
    ref.invalidate(devicesProvider);
    ref.invalidate(avdsProvider);
    ref.invalidate(deviceScreenSizeProvider(serial));
    if (failure != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(failure)));
    }
  }
}
