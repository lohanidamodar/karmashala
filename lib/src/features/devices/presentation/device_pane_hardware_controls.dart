// **The row of hardware buttons under the picture** — Back, Home, Recents, a
// screenshot, a recording, the clipboard, the files browser, a URL and the
// slimming dialog — and the outcome each of them reports.
//
// A part of `device_pane.dart` rather than its own library, for the reason the
// device list gives: the type names are what the pane's committed widget tree
// records, so making them public to move them would cost the proof.
part of 'device_pane.dart';

/// What the pane can do to the Android device it is showing.
///
/// The counterpart of the simulator pane's `_SimulatorControls`, and
/// deliberately the same shape: the hardware keys first, then the three things
/// that need no button on the device at all — appearance, a screenshot, and a
/// URL to open. They used to be Back / Home / Recents and nothing else, so the
/// iOS pane could take a screenshot and follow a deep link while the Android
/// one could not, on the platform where `adb` makes both trivial.
///
/// **Lock is absent, and cannot honestly be added.** `input keyevent
/// KEYCODE_SLEEP` puts the screen out and `KEYCODE_WAKEUP` brings it back, but
/// neither touches the keyguard: on any device with a PIN, pattern or password
/// the wake lands on the lock screen and there is no adb command that gets past
/// it — that is the point of a keyguard. iOS's button is a real Lock/Unlock
/// pair because a simulator has no passcode. A button here promising the same
/// would be a one-way trip on precisely the devices people care about locking.
///
/// [device] is the **live** device, and `null` means no live view — in which
/// case every button is disabled and nothing can reach a phone. The gate is
/// here as well as in the caller because a control that is merely hidden is one
/// refactor away from being effective again, and "silently drives a device the
/// user thinks is disconnected" is the failure this widget must not have.
class _AndroidControls extends ConsumerStatefulWidget {
  const _AndroidControls({
    required this.device,
    this.clipboard,
    this.recordable = false,
  });

  final AndroidDevice? device;

  /// Whether there is a running live view whose frames a recording could be
  /// written from. Not derived from [device]: the pane names the device the
  /// moment the user picks it, and the session takes a second to come up.
  final bool recordable;

  /// The live view's clipboard bridge, or `null` when there is no control
  /// socket to carry one. Not a capability flag: `null` is the only honest
  /// value when the transport is absent, because adb has no clipboard verb to
  /// fall back to.
  final DeviceClipboardBridge? clipboard;

  @override
  ConsumerState<_AndroidControls> createState() => _AndroidControlsState();
}

class _AndroidControlsState extends ConsumerState<_AndroidControls> {
  /// What the last toggle left the appearance in, for the tooltip alone. Null
  /// until one has run, which is why the first tooltip is a guess.
  ///
  /// A guess is all it can be without spending a process on `cmd uimode night`
  /// every time this row is built — and it is a harmless one, because the
  /// *action* does not use it: [_appearance] asks the device what it is
  /// currently doing and flips that. So a device already in dark mode may be
  /// offered "Switch to dark appearance" once, and pressing it still turns the
  /// device light. The simulator row makes the opposite trade for the same
  /// reason in reverse: nothing outside this app moves a simulator's
  /// appearance, so remembering it there is always right.
  bool? _dark;

  AdbService? get _adb => ref.read(adbServiceProvider);

  Future<void> _press(DeviceKey key) async {
    final target = widget.device;
    final adb = _adb;
    if (target == null || adb == null) return;
    await adb.pressKey(target.serial, key);
  }

  Future<void> _appearance() async {
    final target = widget.device;
    final adb = _adb;
    if (target == null || adb == null) return;
    // A device that will not say — `auto`, or a custom schedule, neither of
    // which a two-state button can represent — is treated as light, so the
    // first press has a defined meaning instead of doing nothing.
    final wanted = !(await adb.isNightMode(target.serial) ?? false);
    await adb.setNightMode(target.serial, dark: wanted);
    if (mounted) setState(() => _dark = wanted);
  }

  Future<void> _screenshot() async {
    final target = widget.device;
    final adb = _adb;
    if (target == null || adb == null) return;
    final path = desktopScreenshotPath('Android');
    await adb.screenshot(target.serial, hostPath: path);
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(path == null ? 'Screenshot saved.' : 'Saved to $path'),
        ),
      );
    }
  }

  Future<void> _openUrl() async {
    final url = await askForDeviceUrl(context);
    if (url == null || url.trim().isEmpty) return;
    final target = widget.device;
    final adb = _adb;
    if (target == null || adb == null) return;
    await adb.openUrl(target.serial, url.trim());
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.device;
    // Watched, not read: a pane whose SDK is discovered after the first frame
    // must not be left with a row that can never reach the device.
    final canReach = target != null && ref.watch(adbServiceProvider) != null;
    final recording = ref.watch(deviceRecordingProvider);
    // What container the recording can be, said on the button before it starts.
    final mp4Support = ref.watch(videoSupportProvider);
    const idle = 'Start the live view to use the device controls';
    String tooltip(String label) =>
        target == null ? idle : '$label — ${target.displayName}';

    return DeviceControlBar(
      controls: [
        DeviceControl(
          name: 'Back',
          tooltip: tooltip('Back'),
          icon: AppIcons.arrowLeft,
          onPressed: canReach ? () => _press(DeviceKey.back) : null,
          buttonKey: const Key('android-back'),
        ),
        DeviceControl(
          name: 'Home',
          tooltip: tooltip('Home'),
          icon: AppIcons.circle,
          onPressed: canReach ? () => _press(DeviceKey.home) : null,
          buttonKey: const Key('android-home'),
        ),
        DeviceControl(
          name: 'Recents',
          tooltip: tooltip('Recents'),
          icon: AppIcons.square,
          onPressed: canReach ? () => _press(DeviceKey.recents) : null,
          buttonKey: const Key('android-recents'),
        ),
        DeviceControl(
          name: 'Appearance',
          tooltip: target == null
              ? idle
              : _dark ?? false
              ? 'Switch to light appearance'
              : 'Switch to dark appearance',
          icon: AppIcons.circleHalf,
          onPressed: canReach ? _appearance : null,
          buttonKey: const Key('android-appearance'),
        ),
        DeviceControl(
          name: 'Screenshot',
          tooltip: target == null ? idle : 'Save a screenshot to the Desktop',
          icon: AppIcons.image,
          onPressed: canReach ? _screenshot : null,
          buttonKey: const Key('android-screenshot'),
        ),
        DeviceControl(
          name: 'Open URL',
          tooltip: target == null ? idle : 'Open a URL or deep link',
          icon: AppIcons.globe,
          onPressed: canReach ? _openUrl : null,
          buttonKey: const Key('android-open-url'),
        ),
        // Gated on the live view rather than on adb, because a recording is
        // written from the frames the picture is made of — there is nothing to
        // record without one.
        //
        // Two entries while idle, one while running. The container is the
        // user's choice because the two are not interchangeable: MP4 is what
        // every player opens, MPEG-TS is what survives a rotation. See
        // `DeviceRecordingController.startLiveViewRecording`.
        DeviceControl(
          name: 'Record',
          tooltip: recording is DeviceRecordingActive
              ? 'Stop recording'
              : !widget.recordable
              ? 'Start the live view to record the screen'
              : mp4Support.available
              ? 'Record the screen to an MP4 — the file every player opens'
              : 'Record the screen to an MPEG-TS (.ts) file. '
                    '${mp4Support.detail}',
          icon: recording is DeviceRecordingActive
              ? AppIcons.stopCircle
              : AppIcons.circle,
          onPressed: recording is DeviceRecordingActive
              ? ref.read(deviceRecordingProvider.notifier).stop
              : widget.recordable
              ? () => ref
                    .read(deviceRecordingProvider.notifier)
                    .startLiveViewRecording(
                      container: mp4Support.available
                          ? DeviceRecordingContainer.mp4
                          : DeviceRecordingContainer.transportStream,
                    )
              : null,
          buttonKey: const Key('android-record'),
        ),
        // Only where MP4 is the primary: otherwise the button above already is
        // the transport stream, and two of them would say the same thing.
        if (recording is! DeviceRecordingActive && mp4Support.available)
          DeviceControl(
            name: 'Record .ts',
            tooltip: widget.recordable
                ? 'Record to MPEG-TS instead — the only one that survives the '
                      'device rotating mid-recording'
                : 'Start the live view to record to MPEG-TS',
            icon: AppIcons.circle,
            onPressed: widget.recordable
                ? () => ref
                      .read(deviceRecordingProvider.notifier)
                      .startLiveViewRecording(
                        container: DeviceRecordingContainer.transportStream,
                      )
                : null,
            buttonKey: const Key('android-record-ts'),
          ),
        // The clipboard is gated on the *control socket*, not on adb, which is
        // why these two do not use [canReach]: adb can drive every other
        // button on this row and cannot touch a clipboard at all.
        ...deviceClipboardControls(bridge: widget.clipboard, say: _say),
      ],
    );
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }
}
