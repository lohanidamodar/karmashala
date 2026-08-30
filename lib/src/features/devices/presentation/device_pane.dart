import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../application/device_providers.dart';
import '../data/device_stream.dart';
import '../domain/android_device.dart';
import '../domain/device_geometry.dart';
import '../domain/device_input.dart';
import 'device_touch_surface.dart';

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

  @override
  void dispose() {
    _stopStream();
    super.dispose();
  }

  Future<void> _stopStream() async {
    final session = _session;
    final player = _player;
    _session = null;
    _player = null;
    _video = null;
    _streamingSerial = null;
    await session?.stop();
    await player?.dispose();
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
      setState(() {
        _session = session;
        _player = player;
        _video = controller;
        _streamingSerial = device.serial;
        _starting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _streamError = '$error';
      });
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
          onStart: selected == null ? null : () => _startStream(selected),
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
              : _LiveView(video: _video, device: selected, starting: _starting),
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
    required this.onStart,
    required this.onStop,
  });

  final List<AndroidDevice> devices;
  final AndroidDevice? selected;
  final bool streaming;
  final bool starting;
  final VoidCallback? onStart;
  final VoidCallback? onStop;

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
            tooltip: 'Refresh devices',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(devicesProvider);
              ref.invalidate(avdsProvider);
            },
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
  });

  final VideoController? video;
  final AndroidDevice? device;
  final bool starting;

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

    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: DeviceTouchSurface(
          screen: screen,
          onTap: (x, y) =>
              ref.read(adbServiceProvider)?.tap(currentDevice.serial, x, y),
          // A long press is a swipe that goes nowhere: `input swipe` with the
          // same start and end point held for a duration is exactly the event
          // Android's long-press timeout is waiting for.
          onLongPress: (x, y) => ref
              .read(adbServiceProvider)
              ?.swipe(
                currentDevice.serial,
                fromX: x,
                fromY: y,
                toX: x,
                toY: y,
                duration: kLongPressHoldDuration,
              ),
          onSwipe: (fromX, fromY, toX, toY, duration) => ref
              .read(adbServiceProvider)
              ?.swipe(
                currentDevice.serial,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                duration: duration,
              ),
          child: Video(
            controller: controller,
            fit: BoxFit.fill,
            controls: NoVideoControls,
          ),
        ),
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
