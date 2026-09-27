// The row of hardware buttons under the picture, and what each reports back.
// A part of `device_pane.dart`: the type names are in the committed tree.
part of 'device_pane.dart';

/// What the pane can do to the Android device it is showing. A null [device]
/// means no live view: every button is off, and that gate is here, not above.
class _AndroidControls extends ConsumerStatefulWidget {
  const _AndroidControls({
    required this.device,
    this.clipboard,
    this.recordable = false,
  });

  final AndroidDevice? device;

  /// Whether a running live view's frames could be recorded. Not derived from
  /// [device]: the pane names the device before the session comes up.
  final bool recordable;

  /// The live view's clipboard bridge, `null` when there is no control socket:
  /// not a capability flag, since adb has no clipboard verb to fall back to.
  final DeviceClipboardBridge? clipboard;

  @override
  ConsumerState<_AndroidControls> createState() => _AndroidControlsState();
}

class _AndroidControlsState extends ConsumerState<_AndroidControls> {
  /// What the last toggle left the appearance in, for the tooltip alone — a
  /// guess until one runs; [_appearance] asks the device rather than read it.
  bool? _dark;

  AdbService? get _adb => ref.read(adbServiceProvider);

  /// Whether a person's [verb] may land on the device — asked first when an
  /// agent holds it.
  Future<bool> _mayAct(AndroidDevice target, String verb) =>
      mayActOnDevice(context, ref, target.serial, verb);

  Future<void> _press(DeviceKey key) async {
    final target = widget.device;
    final adb = _adb;
    if (target == null || adb == null) return;
    if (!await _mayAct(target, 'key ${key.name}')) return;
    await adb.pressKey(target.serial, key);
  }

  Future<void> _appearance() async {
    final target = widget.device;
    final adb = _adb;
    if (target == null || adb == null) return;
    if (!await _mayAct(target, 'appearance')) return;
    // A device that will not say — `auto`, or a custom schedule — is treated
    // as light, so the first press means something instead of doing nothing.
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
    if (!mounted || !await _mayAct(target, 'open url')) return;
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
    final mp4Support = ref.watch(deviceVideoSupportProvider);
    const idle = 'Start the live view to use the device controls';
    final recordColor = SemanticColors.of(context).failure;
    String tooltip(String label) =>
        target == null ? idle : '$label — ${target.displayName}';

    // Rebuilt each second while recording, for the elapsed time on Stop.
    return RecordingClock(
      recording: recording,
      builder: (context, now) => DeviceControlBar(
        controls: [
          DeviceControl(
            name: 'Back',
            tooltip: tooltip('Back'),
            // Android's Back, not the app's "go back" arrow.
            icon: AppIcons.arrowUDownLeft,
            onPressed: canReach ? () => _press(DeviceKey.back) : null,
            buttonKey: const Key('android-back'),
          ),
          DeviceControl(
            name: 'Home',
            tooltip: tooltip('Home'),
            icon: AppIcons.house,
            onPressed: canReach ? () => _press(DeviceKey.home) : null,
            buttonKey: const Key('android-home'),
          ),
          DeviceControl(
            name: 'Recents',
            tooltip: tooltip('Recents'),
            icon: AppIcons.squaresFour,
            onPressed: canReach ? () => _press(DeviceKey.recents) : null,
            buttonKey: const Key('android-recents'),
          ),
          // A toggle: the moon is dark appearance, selected while it is on.
          DeviceControl(
            name: 'Appearance',
            tooltip: target == null
                ? idle
                : _dark ?? false
                ? 'Switch to light appearance'
                : 'Switch to dark appearance',
            icon: AppIcons.moon,
            selected: _dark ?? false,
            onPressed: canReach ? _appearance : null,
            buttonKey: const Key('android-appearance'),
          ),
          DeviceControl(
            name: 'Screenshot',
            tooltip: target == null ? idle : 'Save a screenshot to the Desktop',
            icon: AppIcons.camera,
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
          // Gated on the live view, not adb: a recording is written from the
          // picture's frames. MP4 opens anywhere, MPEG-TS survives a rotation.
          DeviceControl(
            name: 'Record',
            tooltip: recording is DeviceRecordingActive
                ? stopRecordingTooltip(recording, now)
                : !widget.recordable
                ? 'Start the live view to record the screen'
                : mp4Support.available
                ? 'Start recording the screen to an MP4 — the file every player '
                      'opens'
                : 'Start recording the screen to an MPEG-TS (.ts) file. '
                      '${mp4Support.detail}',
            // Record in the failure colour, and a solid stop square while it
            // runs — neither is used by any other control in the pane.
            icon: recording is DeviceRecordingActive
                ? AppIcons.stopFill
                : AppIcons.record,
            color: recording is DeviceRecordingActive ? null : recordColor,
            selected: recording is DeviceRecordingActive,
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
                  ? 'Start recording to MPEG-TS instead — the only one that '
                        'survives the device rotating mid-recording'
                  : 'Start the live view to record to MPEG-TS',
              // A video file: the same recording, written as a different file.
              icon: AppIcons.fileVideo,
              onPressed: widget.recordable
                  ? () => ref
                        .read(deviceRecordingProvider.notifier)
                        .startLiveViewRecording(
                          container: DeviceRecordingContainer.transportStream,
                        )
                  : null,
              buttonKey: const Key('android-record-ts'),
            ),
          // The clipboard is gated on the *control socket*, not adb — which is
          // why these two do not use [canReach]: adb cannot reach a clipboard.
          ...deviceClipboardControls(bridge: widget.clipboard, say: _say),
        ],
      ),
    );
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }
}
