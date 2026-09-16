// The picture, and everything layered over it. A part of `device_pane.dart`:
// `_LiveView`'s type name is what the pane's committed widget tree records.
part of 'device_pane.dart';

/// The live picture, plus the tap/drag surface. The [AspectRatio] matches the
/// *device*, so the widget box is the picture and the mapping is a pure scale.
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
    required this.listActions,
  });

  final VideoController? video;

  /// The device this picture is of — never merely the selected one.
  final AndroidDevice? device;
  final bool starting;

  /// Whether [video] is the previous session's held frame. Covered, labelled,
  /// and nothing taps through it: a stale frame must not pass for a live one.
  final bool reconnecting;

  final DeviceGestureSink? sink;

  /// Where keystrokes go. `null` when neither the control socket nor adb can
  /// carry them, which is the one case the surface cannot be armed at all.
  final DeviceKeyboardSink? keyboard;

  final DeviceStreamHealth? health;

  /// Whether automatic reconnection has given up.
  final bool exhausted;

  /// Whether the app is still finding out what is attached. The first listing
  /// costs ~460 ms, and "pick a device below" then reads as "nothing here".
  final bool probing;

  final VoidCallback onRestart;

  /// For the device list shown while there is no picture.
  final _DeviceListActions listActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A spinner only when there is nothing better to show. With a held frame
    // there is.
    if (starting && !reconnecting) {
      return const Center(
        child: InlineSpinner(
          size: InlineSpinnerSize.large,
          semanticsLabel: 'Starting the live view',
        ),
      );
    }
    final controller = video;
    final currentDevice = device;
    if (controller == null || currentDevice == null) {
      return _DeviceEmptyState(
        message: probing
            ? 'Looking for devices…'
            : 'Pick a device below, or start an emulator.',
        actions: listActions,
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
          // it: it is only on while *this* has focus, and the bar says so.
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
                      // Not a Video with an overlay beside it: the two travel
                      // together, so no later edit can un-label a held frame.
                      HeldPicture(
                        deviceLabel: currentDevice.displayName,
                        child: _LivePicture(controller),
                      )
                    else
                      DeviceTouchSurface(
                        sink: sink,
                        child: _LivePicture(controller),
                      ),
                    // A device with nothing new to show is not a fault: a chip
                    // rather than the scrim, with the way out on it.
                    if (idle)
                      Align(
                        alignment: Alignment.topCenter,
                        child: StreamIdleBadge(
                          detail: report!.detail,
                          since: report.since,
                          onRestart: onRestart,
                        ),
                      ),
                    // A stale picture must not pass for a live one: the frame
                    // underneath stays visible, dimmed and labelled.
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

/// The mirrored frames themselves, drawn the one way both the live and the
/// held picture draw them.
class _LivePicture extends StatelessWidget {
  const _LivePicture(this.controller);

  final VideoController controller;

  @override
  Widget build(BuildContext context) => Video(
    controller: controller,
    fit: BoxFit.fill,
    controls: NoVideoControls,
    // media_kit defaults to `low`, a plain bilinear sample; this upscale is on
    // every frame.
    filterQuality: FilterQuality.medium,
  );
}
