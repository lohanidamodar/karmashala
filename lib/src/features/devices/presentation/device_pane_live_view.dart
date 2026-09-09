// **The picture, and everything layered over it** — the live view itself, the
// touch and keyboard surfaces it arms, the overlay that says a held frame is
// not a live one, and what it draws instead when there is no picture yet.
//
// A part of `device_pane.dart` rather than its own library: `_LiveView` is
// private to the pane, and its type name is what the pane's committed widget
// tree records, so making it public to move it would cost the proof.
part of 'device_pane.dart';

/// The live picture, plus the tap/drag surface.
///
/// The video is wrapped in an [AspectRatio] matching the **device** aspect, so
/// the player never letterboxes internally and the widget box is exactly the
/// picture — which is what makes the coordinate mapping a pure scale.
class _LiveView extends ConsumerWidget {
  const _LiveView({
    required this.video,
    required this.device,
    required this.starting,
    required this.reconnecting,
    required this.sink,
    required this.keyboard,
    required this.health,
    required this.exhausted,
    required this.probing,
    required this.onRestart,
    required this.stopping,
    required this.booting,
    required this.onPreview,
    required this.onStopEmulator,
    required this.onBootAvd,
  });

  final VideoController? video;

  /// The device this picture is of — never merely the selected one.
  final AndroidDevice? device;
  final bool starting;

  /// Whether [video] is the previous session's held frame rather than a live
  /// picture. It is covered and labelled while this is true, and nothing taps
  /// through it: a stale frame is the one thing a live view must never be
  /// mistaken for.
  final bool reconnecting;

  final DeviceGestureSink? sink;

  /// Where keystrokes go. `null` when neither the control socket nor adb can
  /// carry them, which is the one case the surface cannot be armed at all.
  final DeviceKeyboardSink? keyboard;

  final DeviceStreamHealth? health;

  /// Whether automatic reconnection has given up.
  final bool exhausted;

  /// Whether the app is still finding out what is attached.
  ///
  /// The first listing costs about 460ms on a Mac — an SDK to discover, `adb`
  /// and `simctl` to ask — and for that time the pane invited the user to
  /// "pick a device below" from a list that had not arrived. Not false, but a
  /// prompt for something nobody could do yet, which reads as "there is
  /// nothing here" the moment it is wrong.
  final bool probing;

  final VoidCallback onRestart;
  final Set<String> stopping;
  final Set<String> booting;
  final Future<void> Function(AndroidDevice device) onPreview;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;
  final Future<void> Function(String name) onBootAvd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A spinner only when there is nothing better to show. With a held frame
    // there is.
    if (starting && !reconnecting) {
      return const Center(child: CircularProgressIndicator());
    }
    final controller = video;
    final currentDevice = device;
    if (controller == null || currentDevice == null) {
      return _DeviceEmptyState(
        message: probing
            ? 'Looking for devices…'
            : 'Pick a device below, or start an emulator.',
        stopping: stopping,
        booting: booting,
        onPreview: onPreview,
        onStopEmulator: onStopEmulator,
        onBootAvd: onBootAvd,
      );
    }
    // The size of the device on screen, asked for by name. Anything derived
    // from "the selection" instead can describe a different device.
    final screen = ref
        .watch(deviceScreenSizeProvider(currentDevice.serial))
        .asData
        ?.value;
    final aspect = screen == null ? 9 / 19.5 : screen.width / screen.height;
    final report = health;
    final unwell = !reconnecting && report != null && !report.isHealthy;
    final idle = !reconnecting && report?.state == DeviceStreamState.idle;

    return Column(
      children: [
        Expanded(
          // Keyboard forwarding wraps the picture rather than sitting beside
          // it: it is only ever on while *this* is what has focus, and the bar
          // it draws underneath has to say so where the user is looking.
          child: DeviceKeyboardSurface(
            sink: keyboard,
            deviceLabel: currentDevice.displayName,
            child: Center(
              child: AspectRatio(
                aspectRatio: aspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (reconnecting)
                      // Not a Video with an overlay next to it: the two travel
                      // together by construction, so no later edit can leave a
                      // held frame passing for a live one.
                      HeldPicture(
                        deviceLabel: currentDevice.displayName,
                        child: Video(
                          controller: controller,
                          fit: BoxFit.fill,
                          controls: NoVideoControls,
                          // media_kit defaults to `low`, which is a plain
                          // bilinear sample. The stream is captured smaller
                          // than the pane draws it, so this upscale is on
                          // every frame and `low` makes a soft picture blocky
                          // as well. Costs nothing on the wire.
                          filterQuality: FilterQuality.medium,
                        ),
                      )
                    else
                      DeviceTouchSurface(
                        sink: sink,
                        child: Video(
                          controller: controller,
                          fit: BoxFit.fill,
                          controls: NoVideoControls,
                          // media_kit defaults to `low`, which is a plain
                          // bilinear sample. The stream is captured smaller
                          // than the pane draws it, so this upscale is on
                          // every frame and `low` makes a soft picture blocky
                          // as well. Costs nothing on the wire.
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    // A device with nothing new to show is not a fault, so it
                    // gets a chip rather than the scrim below — with the way
                    // out on it, because this is the one state the app cannot
                    // be certain about.
                    if (idle)
                      Align(
                        alignment: Alignment.topCenter,
                        child: StreamIdleBadge(
                          detail: report!.detail,
                          since: report.since,
                          onRestart: onRestart,
                        ),
                      ),
                    // A stale picture must not pass for a live one. The frame
                    // underneath is left visible — it is still the last thing
                    // the device showed — but it is dimmed and labelled.
                    if (unwell)
                      StreamStalledOverlay(
                        health: report,
                        exhausted: exhausted,
                        onRestart: onRestart,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        TransportBanner(
          transport: sink?.transport,
          // Naming the device on the picture itself: whatever else drifts, what
          // you are looking at is stated where you are looking.
          deviceLabel: '${currentDevice.displayName} (${currentDevice.serial})',
        ),
      ],
    );
  }
}
