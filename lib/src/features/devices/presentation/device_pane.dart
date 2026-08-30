import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../application/device_providers.dart';
import '../data/device_gesture_sink.dart';
import '../data/device_stream.dart';
import '../domain/android_device.dart';
import '../domain/device_input.dart';
import 'device_stream_status.dart';
import 'device_touch_surface.dart';

/// How long to wait before each automatic reconnection attempt.
///
/// Bounded on purpose. A live view that silently retries forever is the same
/// failure the watchdog exists to end — the user is told after the last one and
/// given the button instead.
const List<Duration> kStreamReconnectBackoff = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

/// What the live view must do when the user's chosen device changes.
enum LiveViewSelectionAction {
  /// Nothing: the live view is off, or it is already on the chosen device.
  none,

  /// Turn the live view off. Nothing is chosen, or what is chosen cannot be
  /// shown — and the previous device's picture must not stay up regardless.
  stop,

  /// Move the live view to the newly chosen device.
  moveTo,
}

/// The rule that keeps the picture and the device picker talking about the same
/// device.
///
/// Pure and public on purpose: it is the whole of the fix for "switching
/// devices leaves the live view on the old device", and the pane it lives in
/// cannot be driven in a widget test — the live view needs a real media_kit
/// `Player`, which needs libmpv.
({LiveViewSelectionAction action, AndroidDevice? device}) liveViewSelection({
  required String? liveSerial,
  required String? selectedSerial,
  required List<AndroidDevice> devices,
}) {
  if (liveSerial == null || selectedSerial == liveSerial) {
    return (action: LiveViewSelectionAction.none, device: null);
  }
  final device = selectedSerial == null
      ? null
      : devices
            .where((candidate) => candidate.serial == selectedSerial)
            .firstOrNull;
  if (device == null || !device.isReady) {
    return (action: LiveViewSelectionAction.stop, device: null);
  }
  return (action: LiveViewSelectionAction.moveTo, device: device);
}

/// The device pane: pick a device or emulator, watch it live, and drive it.
class DevicePane extends ConsumerStatefulWidget {
  const DevicePane({super.key});

  @override
  ConsumerState<DevicePane> createState() => _DevicePaneState();
}

class _DevicePaneState extends ConsumerState<DevicePane> {
  Player? _player;
  VideoController? _video;
  DeviceStreamSession? _session;
  String? _streamError;
  bool _starting = false;

  /// The device the live view is for: whose picture is on screen, whose
  /// coordinate space gestures are mapped through, and whose keys the hardware
  /// buttons press. `null` when the live view is off.
  ///
  /// There used to be two answers to "which device is this pane about" — this
  /// field and [selectedDeviceSerialProvider] — and nothing kept them equal, so
  /// switching devices left the picture on the old one and taps were mapped
  /// through the new one's resolution. The provider is now the source of truth
  /// and this is only ever a *reflection* of it, maintained in exactly one
  /// place: [_onSelectionChanged].
  String? _liveSerial;

  /// Distinguishes an in-flight start from a newer one that has overtaken it.
  ///
  /// Switching device while the first stream is still starting is an ordinary
  /// thing to do, so a start cannot simply refuse to be interrupted; instead
  /// the loser notices it has been superseded and tears its own session down.
  int _startToken = 0;

  /// The stream's own opinion of itself. `null` before the first report.
  DeviceStreamHealth? _health;
  StreamSubscription<DeviceStreamHealth>? _healthSubscription;

  /// Where gestures in the live view go. Swapped for the adb fallback if the
  /// control socket is unavailable or dies mid-session.
  DeviceGestureSink? _sink;

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// Emulators with a shutdown in flight, by serial — one per row, because the
  /// list can offer to stop more than one.
  final Set<String> _stopping = <String>{};

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _disposeSession();
    super.dispose();
  }

  /// Tears the running session down. Leaves [_liveSerial] alone: this is what a
  /// restart or a device switch uses, and both are still "the live view is on".
  Future<void> _disposeSession() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final session = _session;
    final player = _player;
    final health = _healthSubscription;
    _healthSubscription = null;
    _session = null;
    _player = null;
    _video = null;
    _sink = null;
    _health = null;
    await health?.cancel();
    await session?.stop();
    await player?.dispose();
  }

  /// Turns the live view off entirely: no session, and no device it is for.
  Future<void> _stopStream() async {
    _liveSerial = null;
    await _disposeSession();
  }

  /// Keeps the live view on whatever device the user has chosen.
  ///
  /// This is the whole of the fix for "switching devices leaves the live view
  /// on the old device". It deliberately listens to
  /// [selectedDeviceSerialProvider] — the *explicit* choice — and not to the
  /// derived [selectedDeviceProvider], whose "default to the only ready device"
  /// convenience would otherwise move the stream to a different phone by itself
  /// when the streamed emulator died.
  void _onSelectionChanged(String? serial) {
    if (!mounted) return;
    final next = liveViewSelection(
      liveSerial: _liveSerial,
      selectedSerial: serial,
      devices: ref.read(devicesProvider).asData?.value ?? const [],
    );
    switch (next.action) {
      case LiveViewSelectionAction.none:
        return;
      case LiveViewSelectionAction.stop:
        unawaited(_stopAndRebuild());
      case LiveViewSelectionAction.moveTo:
        _reconnectAttempt = 0;
        unawaited(_startStream(next.device!));
    }
  }

  Future<void> _stopAndRebuild() async {
    await _stopStream();
    if (mounted) setState(() {});
  }

  /// Restarts the live view for the device it is already showing.
  ///
  /// Distinct from refreshing the device list, which is what the toolbar's
  /// other button does and what people reached for when the picture froze.
  Future<void> _restartStream({bool manual = true}) async {
    final serial = _liveSerial ?? ref.read(selectedDeviceProvider)?.serial;
    final device = ref
        .read(devicesProvider)
        .asData
        ?.value
        .where((candidate) => candidate.serial == serial)
        .firstOrNull;
    if (device == null) return;
    if (manual) _reconnectAttempt = 0;
    await _startStream(device);
  }

  /// Reacts to the stream reporting itself unwell.
  void _onHealth(DeviceStreamHealth health) {
    if (!mounted) return;
    setState(() => _health = health);
    if (health.isHealthy) {
      _reconnectAttempt = 0;
      return;
    }
    if (_reconnectTimer != null) return;
    if (_reconnectAttempt >= kStreamReconnectBackoff.length) return;
    final delay = kStreamReconnectBackoff[_reconnectAttempt];
    _reconnectAttempt += 1;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (mounted) _restartStream(manual: false);
    });
  }

  Future<void> _startStream(AndroidDevice device) async {
    final service = ref.read(deviceStreamServiceProvider);
    if (service == null || !device.isReady) return;
    // A second press for the device already being started is a no-op; a press
    // for a different one is a switch and must go through.
    if (_starting && _liveSerial == device.serial) return;
    final token = ++_startToken;
    // Set before selecting, so the resulting notification sees the pane already
    // pointed at this device and does not restart what it just started.
    _liveSerial = device.serial;
    // Starting the live view *is* choosing a device. Pinning it here means the
    // toolbar, the picture, the gestures and the hardware keys cannot disagree
    // about which device the pane is about.
    ref.read(selectedDeviceSerialProvider.notifier).select(device.serial);
    setState(() {
      _starting = true;
      _streamError = null;
    });
    await _disposeSession();
    try {
      final session = await service.start(device.serial);
      if (!mounted || token != _startToken) {
        await session.stop();
        return;
      }
      final player = Player(
        configuration: const PlayerConfiguration(
          // A live view wants the newest frame, not a smooth buffer.
          bufferSize: 256 * 1024,
          logLevel: MPVLogLevel.error,
          protocolWhitelist: ['file', 'tcp', 'http'],
        ),
      );
      final native = player.platform as NativePlayer;
      // libmpv defaults to buffering for smooth playback; these make it behave
      // like a monitor. `setProperty` swallows libmpv's return code, so these
      // were verified by reading them back: `profile=low-latency` really is
      // applied (`cache-pause=no`, `video-latency-hacks=yes` and
      // `stream-buffer-size=4096` are the profile's values, not the defaults).
      for (final entry in const {
        'profile': 'low-latency',
        'cache': 'no',
        'demuxer-readahead-secs': '0',
        'demuxer-lavf-analyzeduration': '0',
        // Setting this replaces the whole list, and media_kit's protocol
        // whitelist lives in it — so its entries are repeated here.
        // `flush_packets` was dropped: it is a muxer flag and did nothing.
        'demuxer-lavf-o':
            'fflags=+nobuffer,seg_max_retry=5,strict=experimental,'
            'allowed_extensions=ALL,protocol_whitelist=[file,tcp,http]',
        'untimed': 'yes',
        'vd-lavc-threads': '1',
        'audio': 'no',
      }.entries) {
        await native.setProperty(entry.key, entry.value);
      }
      final controller = VideoController(player);
      await player.open(Media(session.url.toString()));
      if (!mounted || token != _startToken) {
        await session.stop();
        await player.dispose();
        return;
      }
      _healthSubscription = session.health.listen(_onHealth);
      final sink = _controlSink(session);
      setState(() {
        _session = session;
        _player = player;
        _video = controller;
        _starting = false;
        _health = null;
        _sink = sink;
      });
      // No control socket: the adb fallback needs the device's screen size,
      // which is a round trip. Fetched off the start path so a slow `wm size`
      // delays gestures rather than the picture.
      if (sink == null) unawaited(_useAdbSink(session.serial));
    } catch (error) {
      if (!mounted || token != _startToken) return;
      setState(() {
        _starting = false;
        _liveSerial = null;
        _streamError = '$error';
      });
    }
  }

  /// The control-socket gesture sink for a session, or `null` when the session
  /// has no control socket and the adb fallback is needed.
  ///
  /// The two are not equivalent and the pane says which is in use, because a
  /// drag that tracks the finger and a drag that jumps on release are different
  /// products.
  DeviceGestureSink? _controlSink(DeviceStreamSession session) {
    final control = session.control;
    if (control == null) return null;
    return ScrcpyGestureSink(
      connection: control,
      videoSize: () => session.videoSize,
      onDropped: _onControlDropped,
    );
  }

  /// Installs the `adb shell input` gesture sink for [serial].
  ///
  /// The screen size comes from **the device being streamed**, by serial. It
  /// used to come from whatever was selected, which is a different device the
  /// moment the two disagree — and a tap mapped through the wrong resolution
  /// lands in the wrong place while looking like it worked.
  Future<void> _useAdbSink(String serial) async {
    final adb = ref.read(adbServiceProvider);
    if (adb == null) return;
    DeviceScreenSize? size;
    try {
      size = await ref.read(deviceScreenSizeProvider(serial).future);
    } catch (_) {
      size = null;
    }
    final screen = size;
    if (screen == null || !mounted) return;
    // The stream may have moved to another device while we were asking.
    if (_liveSerial != serial || _session?.serial != serial) return;
    setState(
      () => _sink = AdbGestureSink(adb: adb, serial: serial, screen: screen),
    );
  }

  /// The control socket went away mid-session. Fall back rather than going mute.
  void _onControlDropped() {
    final serial = _liveSerial;
    if (!mounted || serial == null || _sink is AdbGestureSink) return;
    unawaited(_useAdbSink(serial));
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
    // produces exactly the frozen picture Loop 36 set out to fix, and it would
    // look like a new fault rather than the shutdown the user asked for.
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

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      selectedDeviceSerialProvider,
      (_, serial) => _onSelectionChanged(serial),
    );
    final sdk = ref.watch(androidSdkProvider);
    final devices = ref.watch(devicesProvider).asData?.value ?? const [];
    final selected = ref.watch(selectedDeviceProvider);
    final reason = deviceUnavailableReason(
      sdk: sdk.asData?.value,
      sdkResolved: sdk.asData != null || sdk.hasError,
      devices: devices,
      kind: ref.watch(deviceEnvironmentProvider).kind,
    );

    // Stop streaming a device that went away.
    if (_liveSerial != null &&
        !devices.any((d) => d.serial == _liveSerial && d.isReady)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_stopAndRebuild());
      });
    }

    // The device the pane is about. While the live view is running it is the
    // device that view is for; the two are the same by construction, and
    // reading it from one place is what keeps them that way.
    final live = _liveSerial == null
        ? null
        : devices.where((d) => d.serial == _liveSerial).firstOrNull;
    final paneDevice = live ?? selected;

    return Column(
      children: [
        _DeviceToolbar(
          devices: devices,
          selected: selected,
          streaming: _liveSerial != null,
          starting: _starting,
          stoppingEmulator:
              selected != null && _stopping.contains(selected.serial),
          onStart: selected == null ? null : () => _startStream(selected),
          onRestart: _liveSerial == null ? null : _restartStream,
          onStopEmulator: selected != null && selected.isEmulator
              ? () => _stopEmulator(
                  serial: selected.serial,
                  label: selected.displayName,
                )
              : null,
          onStop: _liveSerial == null ? null : _stopAndRebuild,
        ),
        const Divider(height: 1),
        Expanded(
          child: reason != null
              ? _DeviceEmptyState(
                  message: reason,
                  stopping: _stopping,
                  onStopEmulator: _stopEmulator,
                )
              : _streamError != null
              ? _DeviceEmptyState(
                  message:
                      'Live view unavailable: $_streamError\n\n'
                      'Screenshots, input and logcat still work.',
                  stopping: _stopping,
                  onStopEmulator: _stopEmulator,
                )
              : _LiveView(
                  video: _video,
                  device: live,
                  starting: _starting,
                  sink: _sink,
                  health: _health,
                  exhausted:
                      _reconnectAttempt >= kStreamReconnectBackoff.length &&
                      _reconnectTimer == null,
                  onRestart: _restartStream,
                  stopping: _stopping,
                  onStopEmulator: _stopEmulator,
                ),
        ),
        if (paneDevice != null) ...[
          const Divider(height: 1),
          _HardwareKeys(device: paneDevice),
        ],
      ],
    );
  }
}

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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: selected?.serial,
                hint: const Text('No device selected'),
                items: [
                  for (final device in devices)
                    DropdownMenuItem(
                      value: device.serial,
                      enabled: device.isReady,
                      child: Text(
                        device.isReady
                            ? '${device.displayName} (${device.serial})'
                            : '${device.displayName} — ${device.state.name}',
                      ),
                    ),
                ],
                // Picking a device here moves the live view with it: the pane is
                // about one device at a time, and the picture follows the picker
                // rather than staying on whatever was streaming first.
                onChanged: (serial) => ref
                    .read(selectedDeviceSerialProvider.notifier)
                    .select(serial),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            // Named for what it does. It used to say "Refresh devices", which
            // is what people pressed when the picture froze — and it refreshed
            // the list, not the stream, so nothing happened.
            tooltip: 'Refresh device list',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(devicesProvider);
              ref.invalidate(avdsProvider);
            },
          ),
          if (onRestart != null)
            IconButton(
              tooltip: 'Restart live view',
              icon: const Icon(Icons.restart_alt),
              onPressed: onRestart,
            ),
          if (onStopEmulator != null)
            IconButton(
              tooltip: 'Stop emulator',
              icon: stoppingEmulator
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.power_settings_new),
              onPressed: stoppingEmulator ? null : onStopEmulator,
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
          else if (streaming)
            TextButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            )
          else
            TextButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Live view'),
            ),
        ],
      ),
    );
  }
}

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
    required this.sink,
    required this.health,
    required this.exhausted,
    required this.onRestart,
    required this.stopping,
    required this.onStopEmulator,
  });

  final VideoController? video;

  /// The device this picture is of — never merely the selected one.
  final AndroidDevice? device;
  final bool starting;
  final DeviceGestureSink? sink;
  final DeviceStreamHealth? health;

  /// Whether automatic reconnection has given up.
  final bool exhausted;

  final VoidCallback onRestart;
  final Set<String> stopping;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (starting) {
      return const Center(child: CircularProgressIndicator());
    }
    final controller = video;
    final currentDevice = device;
    if (controller == null || currentDevice == null) {
      return _DeviceEmptyState(
        message: 'Select a device and start the live view.',
        stopping: stopping,
        onStopEmulator: onStopEmulator,
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
    final unwell = report != null && !report.isHealthy;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DeviceTouchSurface(
                    sink: sink,
                    child: Video(
                      controller: controller,
                      fit: BoxFit.fill,
                      controls: NoVideoControls,
                    ),
                  ),
                  // A stale picture must not pass for a live one. The frame
                  // underneath is left visible — it is still the last thing the
                  // device showed — but it is dimmed and labelled.
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

class _HardwareKeys extends ConsumerWidget {
  const _HardwareKeys({required this.device});

  final AndroidDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> press(DeviceKey key) async {
      final adb = ref.read(adbServiceProvider);
      await adb?.pressKey(device.serial, key);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => press(DeviceKey.back),
          ),
          IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.circle_outlined),
            onPressed: () => press(DeviceKey.home),
          ),
          IconButton(
            tooltip: 'Recents',
            icon: const Icon(Icons.crop_square),
            onPressed: () => press(DeviceKey.recents),
          ),
        ],
      ),
    );
  }
}

class _DeviceEmptyState extends ConsumerWidget {
  const _DeviceEmptyState({
    required this.message,
    required this.stopping,
    required this.onStopEmulator,
  });

  final String message;
  final Set<String> stopping;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smartphone,
                size: 40,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              _EmulatorList(stopping: stopping, onStopEmulator: onStopEmulator),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every emulator this SDK knows about, each with the one action that fits it.
///
/// The stop action lives **here, per row**, and not only on the live-view
/// toolbar. Seeing an emulator running and having no way to shut it down
/// without first starting a video stream of it is the bug this list exists to
/// close: starting a live view is not a prerequisite for ending a process.
class _EmulatorList extends ConsumerWidget {
  const _EmulatorList({required this.stopping, required this.onStopEmulator});

  final Set<String> stopping;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avds = ref.watch(avdsProvider).asData?.value ?? const <Avd>[];
    final devices =
        ref.watch(devicesProvider).asData?.value ?? const <AndroidDevice>[];
    final named = {
      for (final avd in avds)
        if (avd.runningSerial != null) avd.runningSerial!,
    };
    // A running emulator with no AVD row: this SDK has no emulator package to
    // list AVDs with, or it booted from an AVD this SDK cannot see. It is still
    // a running emulator and it is still stoppable.
    final unnamed = [
      for (final device in devices)
        if (device.isEmulator &&
            device.isReady &&
            !named.contains(device.serial))
          device,
    ];
    if (avds.isEmpty && unnamed.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Text('Emulators', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        for (final avd in avds)
          _EmulatorRow(
            title: avd.name,
            serial: avd.runningSerial,
            stopping:
                avd.runningSerial != null &&
                stopping.contains(avd.runningSerial),
            onStart: avd.isRunning
                ? null
                : () async {
                    final adb = ref.read(adbServiceProvider);
                    await adb?.bootAvd(avd.name);
                  },
            onStop: avd.runningSerial == null
                ? null
                : () => onStopEmulator(
                    serial: avd.runningSerial!,
                    label: avd.name,
                  ),
          ),
        for (final device in unnamed)
          _EmulatorRow(
            title: device.displayName,
            serial: device.serial,
            stopping: stopping.contains(device.serial),
            onStart: null,
            onStop: () => onStopEmulator(
              serial: device.serial,
              label: device.displayName,
            ),
          ),
      ],
    );
  }
}

class _EmulatorRow extends StatelessWidget {
  const _EmulatorRow({
    required this.title,
    required this.serial,
    required this.stopping,
    required this.onStart,
    required this.onStop,
  });

  final String title;

  /// Serial of the running emulator, or `null` when this AVD is not running.
  final String? serial;
  final bool stopping;
  final VoidCallback? onStart;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final running = serial != null;
    return ListTile(
      dense: true,
      title: Text(title),
      subtitle: running ? Text('running · $serial') : null,
      trailing: running
          ? TextButton(
              key: Key('stop-emulator-$serial'),
              onPressed: stopping ? null : onStop,
              child: stopping
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Stop'),
            )
          : TextButton(
              key: Key('start-avd-$title'),
              onPressed: onStart,
              child: const Text('Start'),
            ),
    );
  }
}
