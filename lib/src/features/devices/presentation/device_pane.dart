import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/device_providers.dart';
import '../data/device_gesture_sink.dart';
import '../data/device_keyboard_sink.dart';
import '../data/device_stream.dart';
import '../application/ios_device_providers.dart';
import '../domain/android_device.dart';
import '../domain/ios_simulator.dart';
import '../domain/device_input.dart';
import 'device_keyboard_surface.dart';
import 'device_stream_status.dart';
import '../application/simulator_live_view.dart';
import 'simulator_live_pane.dart';
import 'simulator_list.dart';
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

  /// Where keystrokes go while the live view has focus. Same story as [_sink]:
  /// the control socket when there is one, `adb shell input` when there is not.
  /// Whether they are *going* is [DeviceKeyboardSurface]'s to know — it is a
  /// question about focus, and focus lives down there.
  DeviceKeyboardSink? _keyboardSink;

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// Emulators with a shutdown in flight, by serial — one per row, because the
  /// list can offer to stop more than one.
  final Set<String> _stopping = <String>{};

  /// AVDs with a boot in flight, by AVD name. Headless there is nothing to
  /// watch, so the row has to say it is starting or the click looks ignored.
  final Set<String> _booting = <String>{};

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
    _keyboardSink = null;
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
        // The keyboard needs no screen size, so it is available immediately in
        // either transport — a gesture has to wait for `wm size`, a keystroke
        // does not.
        _keyboardSink = _keyboardSinkFor(session);
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

  /// Where keystrokes for [session] go.
  ///
  /// Unlike gestures this never returns `null` for want of a screen size: the
  /// control socket if there is one, `adb shell input` if there is not, and
  /// `null` only when there is no adb either — which the pane states rather
  /// than swallowing keys.
  DeviceKeyboardSink? _keyboardSinkFor(DeviceStreamSession session) {
    final control = session.control;
    if (control != null) {
      return ScrcpyKeyboardSink(
        connection: control,
        onDropped: _onControlDropped,
      );
    }
    final adb = ref.read(adbServiceProvider);
    if (adb == null) return null;
    return AdbKeyboardSink(adb: adb, serial: session.serial);
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
    if (!mounted || serial == null) return;
    final adb = ref.read(adbServiceProvider);
    if (adb != null && _keyboardSink is! AdbKeyboardSink) {
      // The keyboard falls back on its own: it does not need the screen size
      // the gesture sink is about to go and fetch.
      setState(
        () => _keyboardSink = AdbKeyboardSink(adb: adb, serial: serial),
      );
    }
    if (_sink is AdbGestureSink) return;
    unawaited(_useAdbSink(serial));
  }

  /// Boots an AVD and opens the live view on it.
  ///
  /// One flow, not two steps: with `-no-window` the live view is the only way
  /// to see the thing that was just started, so starting it and showing it are
  /// the same intent.
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
      );
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
          // The simulator's picture wins while it is up. It is the only thing
          // on screen the user asked for by name, and the Android branches
          // below are all about a device they did not pick.
          child: ref.watch(simulatorLiveViewProvider)
                  is! SimulatorLiveViewIdle
              ? const SimulatorLivePane()
              : reason != null
              ? _DeviceEmptyState(
                  message: reason,
                  stopping: _stopping,
                  booting: _booting,
                  onPreview: _startStream,
                  onStopEmulator: _stopEmulator,
                  onBootAvd: _bootAvd,
                )
              : _streamError != null
              ? _DeviceEmptyState(
                  message:
                      'Live view unavailable: $_streamError\n\n'
                      'Screenshots, input and logcat still work.',
                  stopping: _stopping,
                  booting: _booting,
                  onPreview: _startStream,
                  onStopEmulator: _stopEmulator,
                  onBootAvd: _bootAvd,
                )
              : _LiveView(
                  video: _video,
                  device: live,
                  starting: _starting,
                  sink: _sink,
                  keyboard: _keyboardSink,
                  health: _health,
                  exhausted:
                      _reconnectAttempt >= kStreamReconnectBackoff.length &&
                      _reconnectTimer == null,
                  onRestart: _restartStream,
                  stopping: _stopping,
                  booting: _booting,
                  onPreview: _startStream,
                  onStopEmulator: _stopEmulator,
                  onBootAvd: _bootAvd,
                ),
        ),
        if (paneDevice != null) ...[
          const Divider(height: 1),
          // Deliberately [live], not [paneDevice]: a hardware key is *input*,
          // and input follows the running session rather than the selection.
          // Stopping the live view used to leave these driving whichever device
          // happened to be selected — the user believed they had disconnected
          // and had not. The row stays on screen, disabled, because a control
          // that vanishes reads as a fault while an inert one says why.
          _HardwareKeys(device: live),
        ],
      ],
    );
  }
}

/// Prefixes that keep an Android serial and a simulator udid apart in the one
/// picker. Both are opaque strings, and a value that could be either would make
/// the selection ambiguous the first time a serial looked like a udid.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Android devices and booted simulators in one list. They are the same
    // thing to the user — a device with a screen they want to see — and keeping
    // them apart meant a booted simulator was invisible in the picker that is
    // supposed to name what the pane is about.
    final simulators = ref.watch(bootedSimulatorsProvider);
    final chosenSimulator = ref.watch(selectedSimulatorUdidProvider);
    final simulatorSelected =
        selected == null &&
        chosenSimulator != null &&
        simulators.any((s) => s.udid == chosenSimulator);
    final simulatorStreaming =
        ref.watch(simulatorLiveViewProvider) is! SimulatorLiveViewIdle;
    // Without a backend a simulator can still be listed, started and stopped;
    // only the picture is unavailable.
    final canMirror = ref.watch(simulatorBackendProvider) != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              // `DropdownButton` is Material 2, and the app's
              // `dropdownMenuTheme` reaches only Material 3's `DropdownMenu` —
              // so this control quietly fell back to Material's own defaults
              // and came out at ~16 px with a 24 px chevron, against chrome
              // that is `bodySmall` with a `Chrome.icon` glyph. That size is
              // what made "CPH1989 (F6IZLV6LMFT4U4ZT)" wrap onto two lines,
              // not the serial: at `bodySmall` the whole label fits, and the
              // serial earns its place here because it is what tells two
              // identical handsets apart in the picker itself. The ellipsis is
              // the backstop for a pane narrow enough that it still cannot.
              child: DropdownButton<String>(
                isExpanded: true,
                isDense: true,
                style: theme.textTheme.bodySmall,
                iconSize: Chrome.icon,
                value: selected != null
                    ? '$_androidValue${selected!.serial}'
                    : simulatorSelected
                    ? '$_simulatorValue$chosenSimulator'
                    : null,
                hint: Text(
                  'No device selected',
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
                // Picking a device here moves the live view with it: the pane is
                // about one device at a time, and the picture follows the picker
                // rather than staying on whatever was streaming first.
                //
                // Picking one kind clears the other, so the picker always shows
                // exactly what the pane is about rather than two selections
                // disagreeing about it.
                onChanged: (value) {
                  if (value == null) return;
                  if (value.startsWith(_simulatorValue)) {
                    ref.read(selectedDeviceSerialProvider.notifier).select(null);
                    ref
                        .read(selectedSimulatorUdidProvider.notifier)
                        .select(value.substring(_simulatorValue.length));
                  } else {
                    ref.read(selectedSimulatorUdidProvider.notifier).select(null);
                    ref
                        .read(selectedDeviceSerialProvider.notifier)
                        .select(value.substring(_androidValue.length));
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            // Named for what it does. It used to say "Refresh devices", which
            // is what people pressed when the picture froze — and it refreshed
            // the list, not the stream, so nothing happened.
            tooltip: 'Refresh device list',
            icon: const Icon(AppIcons.arrowsClockwise),
            onPressed: () {
              ref.invalidate(devicesProvider);
              ref.invalidate(avdsProvider);
              ref.invalidate(iosSimulatorsProvider);
            },
          ),
          if (onRestart != null)
            IconButton(
              tooltip: 'Restart live view',
              icon: const Icon(AppIcons.arrowCounterClockwise),
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
                  : const Icon(AppIcons.power),
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
          else if (simulatorSelected ? simulatorStreaming : streaming)
            TextButton.icon(
              onPressed: simulatorSelected
                  ? () => ref.read(simulatorLiveViewProvider.notifier).stop()
                  : onStop,
              icon: const Icon(AppIcons.stop),
              label: const Text('Stop'),
            )
          else
            TextButton.icon(
              onPressed: simulatorSelected
                  ? (canMirror
                        ? () => ref
                              .read(simulatorLiveViewProvider.notifier)
                              .start(chosenSimulator)
                        : null)
                  : onStart,
              icon: const Icon(AppIcons.play),
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
    required this.keyboard,
    required this.health,
    required this.exhausted,
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
  final DeviceGestureSink? sink;

  /// Where keystrokes go. `null` when neither the control socket nor adb can
  /// carry them, which is the one case the surface cannot be armed at all.
  final DeviceKeyboardSink? keyboard;

  final DeviceStreamHealth? health;

  /// Whether automatic reconnection has given up.
  final bool exhausted;

  final VoidCallback onRestart;
  final Set<String> stopping;
  final Set<String> booting;
  final Future<void> Function(AndroidDevice device) onPreview;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;
  final Future<void> Function(String name) onBootAvd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (starting) {
      return const Center(child: CircularProgressIndicator());
    }
    final controller = video;
    final currentDevice = device;
    if (controller == null || currentDevice == null) {
      return _DeviceEmptyState(
        message: 'Pick a device below, or start an emulator.',
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
    final unwell = report != null && !report.isHealthy;

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
                    DeviceTouchSurface(
                      sink: sink,
                      child: Video(
                        controller: controller,
                        fit: BoxFit.fill,
                        controls: NoVideoControls,
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

/// Back / Home / Recents for the device the live view is running on.
///
/// [device] is the **live** device, and `null` means no live view — in which
/// case every button is disabled and nothing can reach a phone. The gate is
/// here as well as in the caller because a control that is merely hidden is one
/// refactor away from being effective again, and "silently drives a device the
/// user thinks is disconnected" is the failure this widget must not have.
class _HardwareKeys extends ConsumerWidget {
  const _HardwareKeys({required this.device});

  final AndroidDevice? device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = device;
    Future<void> press(DeviceKey key) async {
      if (target == null) return;
      final adb = ref.read(adbServiceProvider);
      await adb?.pressKey(target.serial, key);
    }

    const idle = 'Start the live view to use the hardware keys';
    Widget button(String label, IconData icon, DeviceKey key) => IconButton(
      tooltip: target == null ? idle : '$label — ${target.displayName}',
      icon: Icon(icon),
      onPressed: target == null ? null : () => press(key),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          button('Back', AppIcons.arrowLeft, DeviceKey.back),
          button('Home', AppIcons.circle, DeviceKey.home),
          button('Recents', AppIcons.square, DeviceKey.recents),
        ],
      ),
    );
  }
}

class _DeviceEmptyState extends ConsumerWidget {
  const _DeviceEmptyState({
    required this.message,
    required this.stopping,
    required this.booting,
    required this.onPreview,
    required this.onStopEmulator,
    required this.onBootAvd,
  });

  final String message;
  final Set<String> stopping;
  final Set<String> booting;
  final Future<void> Function(AndroidDevice device) onPreview;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;
  final Future<void> Function(String name) onBootAvd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.deviceMobile,
                size: 40,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              // Above both lists, because it governs both. It used to sit
              // inside the Emulators section, which meant a Mac with Xcode and
              // no Android SDK — where the only startable devices are iOS
              // simulators — never saw the switch that decides how they start.
              const _HeadlessDeviceToggle(),
              _DeviceList(
                stopping: stopping,
                booting: booting,
                onPreview: onPreview,
                onStopEmulator: onStopEmulator,
                onBootAvd: onBootAvd,
              ),
              // Below the Android sections, and independent of them: a Mac with
              // Xcode and no Android SDK still has simulators to start, and the
              // message above — which is about the missing SDK — must not be
              // the end of the pane there.
              const SimulatorList(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything the pane can be pointed at — the devices adb can see and the AVDs
/// that could be booted — in one list, each row offering what makes sense for
/// what it is.
///
/// The actions live **here, per row**, and not only on the toolbar. Stop in
/// particular: seeing an emulator running and having no way to shut it down
/// without first starting a video stream of it is the bug this list exists to
/// close. Starting a live view is not a prerequisite for ending a process.
///
/// Rows that cannot be used say why instead of being silently inert.
class _DeviceList extends ConsumerWidget {
  const _DeviceList({
    required this.stopping,
    required this.booting,
    required this.onPreview,
    required this.onStopEmulator,
    required this.onBootAvd,
  });

  final Set<String> stopping;
  final Set<String> booting;
  final Future<void> Function(AndroidDevice device) onPreview;
  final Future<void> Function({required String serial, required String label})
  onStopEmulator;
  final Future<void> Function(String name) onBootAvd;

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
    final theme = Theme.of(context);
    final devices =
        ref.watch(devicesProvider).asData?.value ?? const <AndroidDevice>[];
    // A booted simulator is a connected device. It was listed in its own
    // section under the *idle* emulators, which put the one thing running
    // below the things that are not.
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
    if (devices.isEmpty && idle.isEmpty && simulators.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (devices.isNotEmpty || simulators.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Connected', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final simulator in simulators)
            _DeviceRow(
              key: Key('simulator-${simulator.udid}'),
              title: simulator.name,
              subtitle: switch (simulator.state) {
                SimulatorState.booting => 'starting…',
                SimulatorState.shuttingDown => 'shutting down…',
                _ => 'running · ${simulator.runtimeName}',
              },
              actions: [
                if (canMirror && simulator.state.isReady)
                  _RowAction(
                    key: Key('live-view-${simulator.udid}'),
                    label: 'Live view',
                    busy: busySimulators.contains(simulator.udid),
                    onPressed: () async => ref
                        .read(simulatorLiveViewProvider.notifier)
                        .start(simulator.udid),
                  ),
                if (simulator.state.isReady)
                  _RowAction(
                    key: Key('stop-simulator-${simulator.udid}'),
                    label: 'Stop',
                    busy: busySimulators.contains(simulator.udid),
                    onPressed: () async => ref
                        .read(simulatorTransitionsProvider.notifier)
                        .shutdown(simulator.udid),
                  ),
              ],
            ),
          for (final device in devices)
            _DeviceRow(
              title: runningAvdNames[device.serial] ?? device.displayName,
              subtitle: _stateLine(device),
              actions: [
                if (device.isReady)
                  _RowAction(
                    key: Key('preview-${device.serial}'),
                    label: 'Live preview',
                    onPressed: () => onPreview(device),
                  ),
                // Only emulators: `emu kill` talks to the emulator console, so
                // on a phone it could only ever fail.
                if (device.isReady && device.isEmulator)
                  _RowAction(
                    key: Key('stop-emulator-${device.serial}'),
                    label: 'Stop',
                    busy: stopping.contains(device.serial),
                    onPressed: () => onStopEmulator(
                      serial: device.serial,
                      label:
                          runningAvdNames[device.serial] ?? device.displayName,
                    ),
                  ),
              ],
            ),
        ],
        if (idle.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Emulators', style: theme.textTheme.labelLarge),
          for (final avd in idle)
            _DeviceRow(
              title: avd.name,
              subtitle: booting.contains(avd.name) ? 'starting…' : null,
              actions: [
                _RowAction(
                  key: Key('start-avd-${avd.name}'),
                  label: 'Start',
                  busy: booting.contains(avd.name),
                  onPressed: () => onBootAvd(avd.name),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

/// One action on a device row. A spinner replaces the label while it runs,
/// because with a headless emulator nothing else on screen changes.
class _RowAction extends StatelessWidget {
  const _RowAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.title,
    required this.subtitle,
    required this.actions,
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, overflow: TextOverflow.ellipsis),
      trailing: actions.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: actions),
    );
  }
}


/// The one switch that decides whether a started device gets a window.
///
/// Hidden when there is nothing to start: a switch about starting devices is
/// noise on a machine with none, and the empty state already says why there
/// are none.
///
/// The subtitle names both platforms because the switch means opposite
/// mechanics on each — `-no-window` for an AVD, and *not* opening
/// Simulator.app for an iOS device, which `simctl` never opens by itself.
/// What it promises the user is the same on both, so that is what it says.
class _HeadlessDeviceToggle extends ConsumerWidget {
  const _HeadlessDeviceToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idleAvds = (ref.watch(avdsProvider).asData?.value ?? const <Avd>[])
        .where((avd) => !avd.isRunning)
        .isNotEmpty;
    final startableSimulators = ref.watch(startableSimulatorsProvider).isNotEmpty;
    if (!idleAvds && !startableSimulators) return const SizedBox.shrink();

    final both = idleAvds && startableSimulators;
    return SwitchListTile(
      key: const Key('headless-emulator-toggle'),
      dense: true,
      value: ref.watch(headlessDeviceProvider),
      onChanged: (value) =>
          ref.read(headlessDeviceProvider.notifier).update(value),
      title: const Text('Start without a window'),
      subtitle: Text(
        both
            ? 'Watch it here instead. Turn off for the emulator\'s extended '
                  'controls, or the Simulator app.'
            : startableSimulators
            ? 'Watch it here instead. Turn off to open the Simulator app too.'
            : 'Watch it here instead. Turn off for the emulator\'s own '
                  'extended controls.',
      ),
    );
  }
}
