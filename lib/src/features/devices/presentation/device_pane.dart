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
  String? _streamingSerial;
  String? _streamError;
  bool _starting = false;

  /// The stream's own opinion of itself. `null` before the first report.
  DeviceStreamHealth? _health;
  StreamSubscription<DeviceStreamHealth>? _healthSubscription;

  /// Where gestures in the live view go. Swapped for the adb fallback if the
  /// control socket is unavailable or dies mid-session.
  DeviceGestureSink? _sink;

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _stoppingEmulator = false;

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _stopStream();
    super.dispose();
  }

  Future<void> _stopStream() async {
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
    _streamingSerial = null;
    await health?.cancel();
    await session?.stop();
    await player?.dispose();
  }

  /// Restarts the live view for the device it is already showing.
  ///
  /// Distinct from refreshing the device list, which is what the toolbar's
  /// other button does and what people reached for when the picture froze.
  Future<void> _restartStream({bool manual = true}) async {
    final serial = _streamingSerial ?? ref.read(selectedDeviceProvider)?.serial;
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
    if (service == null || _starting) return;
    setState(() {
      _starting = true;
      _streamError = null;
    });
    await _stopStream();
    try {
      final session = await service.start(device.serial);
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
      if (!mounted) {
        await session.stop();
        await player.dispose();
        return;
      }
      _healthSubscription = session.health.listen(_onHealth);
      setState(() {
        _session = session;
        _player = player;
        _video = controller;
        _streamingSerial = device.serial;
        _starting = false;
        _health = null;
        _sink = _buildSink(session, device);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _streamError = '$error';
      });
    }
  }

  /// Chooses the gesture transport for a session.
  ///
  /// The control socket when there is one, `adb shell input` otherwise. The two
  /// are not equivalent and the pane says which is in use, because a drag that
  /// tracks the finger and a drag that jumps on release are different products.
  DeviceGestureSink? _buildSink(
    DeviceStreamSession session,
    AndroidDevice device,
  ) {
    final control = session.control;
    if (control != null) {
      return ScrcpyGestureSink(
        connection: control,
        videoSize: () => session.videoSize,
        onDropped: _onControlDropped,
      );
    }
    return _adbSink(device);
  }

  DeviceGestureSink? _adbSink(AndroidDevice device) {
    final adb = ref.read(adbServiceProvider);
    final screen = ref.read(selectedDeviceScreenSizeProvider).asData?.value;
    if (adb == null || screen == null) return null;
    return AdbGestureSink(adb: adb, serial: device.serial, screen: screen);
  }

  /// The control socket went away mid-session. Fall back rather than going mute.
  void _onControlDropped() {
    if (!mounted) return;
    final serial = _streamingSerial;
    if (serial == null || _sink is AdbGestureSink) return;
    final device = ref
        .read(devicesProvider)
        .asData
        ?.value
        .where((candidate) => candidate.serial == serial)
        .firstOrNull;
    if (device == null) return;
    setState(() => _sink = _adbSink(device));
  }

  Future<void> _stopEmulator(AndroidDevice device) async {
    final adb = ref.read(adbServiceProvider);
    if (adb == null || _stoppingEmulator) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop ${device.displayName}?'),
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
    setState(() => _stoppingEmulator = true);
    // Take the stream down first: killing the emulator underneath a live view
    // produces exactly the frozen picture this loop set out to fix, and it
    // would look like a new fault rather than the shutdown the user asked for.
    if (_streamingSerial == device.serial) await _stopStream();
    String? failure;
    try {
      final stopped = await adb.stopEmulator(device.serial);
      if (!stopped) {
        failure = '${device.displayName} did not exit.';
      }
    } catch (error) {
      failure = '$error';
    }
    if (!mounted) return;
    setState(() => _stoppingEmulator = false);
    ref.invalidate(devicesProvider);
    ref.invalidate(avdsProvider);
    if (failure != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  @override
  Widget build(BuildContext context) {
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
    if (_streamingSerial != null &&
        !devices.any((d) => d.serial == _streamingSerial && d.isReady)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _stopStream().then((_) {
            if (mounted) setState(() {});
          });
        }
      });
    }

    return Column(
      children: [
        _DeviceToolbar(
          devices: devices,
          selected: selected,
          streaming: _streamingSerial != null,
          starting: _starting,
          stoppingEmulator: _stoppingEmulator,
          onStart: selected == null ? null : () => _startStream(selected),
          onRestart: _streamingSerial == null ? null : _restartStream,
          onStopEmulator: selected != null && selected.isEmulator
              ? () => _stopEmulator(selected)
              : null,
          onStop: _streamingSerial == null
              ? null
              : () async {
                  await _stopStream();
                  if (mounted) setState(() {});
                },
        ),
        const Divider(height: 1),
        Expanded(
          child: reason != null
              ? _DeviceEmptyState(message: reason)
              : _streamError != null
              ? _DeviceEmptyState(
                  message:
                      'Live view unavailable: $_streamError\n\n'
                      'Screenshots, input and logcat still work.',
                )
              : _LiveView(
                  video: _video,
                  device: selected,
                  starting: _starting,
                  sink: _sink,
                  health: _health,
                  exhausted:
                      _reconnectAttempt >= kStreamReconnectBackoff.length &&
                      _reconnectTimer == null,
                  onRestart: _restartStream,
                ),
        ),
        if (selected != null) ...[
          const Divider(height: 1),
          _HardwareKeys(device: selected),
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
  });

  final VideoController? video;
  final AndroidDevice? device;
  final bool starting;
  final DeviceGestureSink? sink;
  final DeviceStreamHealth? health;

  /// Whether automatic reconnection has given up.
  final bool exhausted;

  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (starting) {
      return const Center(child: CircularProgressIndicator());
    }
    final controller = video;
    final currentDevice = device;
    if (controller == null || currentDevice == null) {
      return const _DeviceEmptyState(
        message: 'Select a device and start the live view.',
      );
    }
    final screen = ref.watch(selectedDeviceScreenSizeProvider).asData?.value;
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
                    _StreamStalledOverlay(
                      health: report,
                      exhausted: exhausted,
                      onRestart: onRestart,
                    ),
                ],
              ),
            ),
          ),
        ),
        _TransportBanner(sink: sink),
      ],
    );
  }
}

/// Covers a frozen live view, says what happened, and offers the way out.
class _StreamStalledOverlay extends StatelessWidget {
  const _StreamStalledOverlay({
    required this.health,
    required this.exhausted,
    required this.onRestart,
  });

  final DeviceStreamHealth health;
  final bool exhausted;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ended = health.state == DeviceStreamState.ended;
    return ColoredBox(
      color: theme.colorScheme.scrim.withValues(alpha: 0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ended ? Icons.link_off : Icons.pause_circle_outline,
                color: theme.colorScheme.onInverseSurface,
              ),
              const SizedBox(height: 8),
              Text(
                ended ? 'Live view disconnected' : 'Live view frozen',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                health.detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
              if (health.serverLog.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  health.serverLog.last,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onInverseSurface.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onRestart,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Restart live view'),
              ),
              if (!exhausted) ...[
                const SizedBox(height: 6),
                Text(
                  'Reconnecting…',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Says which transport the live view's gestures are using.
///
/// Not a debug detail: on the control socket a drag tracks the finger, and on
/// `adb shell input` nothing moves until release. Someone wondering why the
/// pane feels different today deserves to be able to see why.
class _TransportBanner extends StatelessWidget {
  const _TransportBanner({required this.sink});

  final DeviceGestureSink? sink;

  @override
  Widget build(BuildContext context) {
    final transport = sink?.transport;
    final theme = Theme.of(context);
    final text = switch (transport) {
      null => 'Input unavailable',
      DeviceGestureTransport.scrcpyControl =>
        'Control socket — continuous touch. $kPinchHint.',
      DeviceGestureTransport.adbInput =>
        'adb input fallback — gestures apply on release, no pinch.',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            transport?.isContinuous ?? false
                ? Icons.touch_app
                : Icons.info_outline,
            size: 14,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
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
  const _DeviceEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avds = ref.watch(avdsProvider).asData?.value ?? const <Avd>[];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
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
            if (avds.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Emulators', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final avd in avds)
                ListTile(
                  dense: true,
                  title: Text(avd.name),
                  subtitle: avd.isRunning ? const Text('running') : null,
                  trailing: avd.isRunning
                      ? null
                      : TextButton(
                          onPressed: () async {
                            final adb = ref.read(adbServiceProvider);
                            await adb?.bootAvd(avd.name);
                          },
                          child: const Text('Start'),
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
