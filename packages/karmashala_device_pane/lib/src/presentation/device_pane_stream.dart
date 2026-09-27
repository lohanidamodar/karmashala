// The live view's session — everything the pane does that is not drawing.
// A mixin, applied after WidgetsBindingObserver to keep the override order.
part of 'device_pane.dart';

/// Shared by the pane and the native-player verification probe.
Future<void> configureDeviceLivePlayer(
  Future<void> Function(String, String) setProperty,
) async {
  for (final entry in const {
    'profile': 'low-latency',
    // A static screen sends nothing. media_kit's 5s timeout makes libmpv
    // mark this live stream EOF and pause. The session owns liveness instead.
    'network-timeout': '0',
    'cache': 'no',
    'demuxer-readahead-secs': '0',
    'demuxer-lavf-analyzeduration': '0',
    // Replacing this list must preserve media_kit's protocol whitelist.
    'demuxer-lavf-o':
        'fflags=+nobuffer,seg_max_retry=5,strict=experimental,'
        'allowed_extensions=ALL,protocol_whitelist=[file,tcp,http]',
    // Preserve the last picture while a replacement player is opening.
    'keep-open': 'yes',
    'untimed': 'yes',
    'vd-lavc-threads': '1',
    'audio': 'no',
  }.entries) {
    await setProperty(entry.key, entry.value);
  }
}

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

/// The rule that keeps the picture and the device picker on one device.
/// Pure and public because the pane itself cannot be driven in a widget test.
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

/// Runs [open] over something already started; when it throws, [release] runs
/// first so a failed start does not leak what was built before the failure.
Future<T> openOrRelease<T>({
  required Future<T> Function() open,
  required Future<void> Function() release,
}) async {
  try {
    return await open();
  } catch (_) {
    try {
      await release();
    } on Object {
      // The failure that started this is the one to report.
    }
    rethrow;
  }
}

mixin _DeviceLiveStream on ConsumerState<DevicePane>, WidgetsBindingObserver {
  Player? _player;
  VideoController? _video;
  DeviceStreamSession? _session;
  String? _streamError;
  bool _starting = false;

  /// The device the live view is for, `null` when off: only ever a reflection
  /// of [selectedDeviceSerialProvider], kept there so it survives a remount.
  String? get _liveSerial => ref.read(androidLiveViewProvider);
  set _liveSerial(String? serial) =>
      ref.read(androidLiveViewProvider.notifier).select(serial);

  /// A live view being brought back after a remount. Kept apart from
  /// [_starting], which refuses a second start — a resume must be let through.
  bool _resuming = false;

  /// Distinguishes an in-flight start from a newer one that overtook it; the
  /// loser notices it has been superseded and tears its own session down.
  int _startToken = 0;

  /// The stream's own opinion of itself. `null` before the first report.
  DeviceStreamHealth? _health;
  StreamSubscription<DeviceStreamHealth>? _healthSubscription;

  /// Where gestures in the live view go. Swapped for the adb fallback if the
  /// control socket is unavailable or dies mid-session.
  DeviceGestureSink? _sink;

  /// Where keystrokes go while the live view has focus. Same story as [_sink]:
  /// the control socket when there is one, `adb shell input` when there is not.
  DeviceKeyboardSink? _keyboardSink;

  /// The device's clipboard over the control socket. `null` with no socket,
  /// and deliberately no adb fallback — adb has no clipboard verb at all.
  DeviceClipboardBridge? _clipboard;

  /// The previous session's player, kept alive across a restart so the last
  /// frame it decoded stays on screen instead of the picture going blank.
  Player? _heldPlayer;
  VideoController? _heldVideo;

  /// Whether the picture on screen belongs to the session being replaced —
  /// held across the whole restart, not derived from which field it is in.
  bool _holdingPicture = false;

  Timer? _reconnectTimer;

  /// Lets go of this session's [PickerQuiet] registration. The session, not
  /// the pane: the rule is about the isolate a host file dialog shares.
  VoidCallback? _releaseQuiet;

  /// When an unwell stream is worth restarting, and how long to wait first.
  final StreamRestartPolicy _restarts = StreamRestartPolicy();

  static final AppLogger _log = AppLogger.named('device-stream');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The side panel unmounts this pane on every surface switch; what
    // survives is the intent, and this is what acts on it.
    final serial = ref.read(androidLiveViewProvider);
    if (serial != null) {
      // From the first frame, so the pane does not flash "pick a device" on
      // its way back to a live view it is about to have.
      _resuming = true;
      unawaited(_resumeLiveView(serial));
    }
  }

  /// Puts the live view back on the device it was on before the unmount. The
  /// list is awaited: one still loading reads as an unplugged phone.
  Future<void> _resumeLiveView(String serial) async {
    List<AndroidDevice> devices;
    try {
      devices = await ref.read(devicesProvider.future);
    } on Object {
      devices = const [];
    }
    if (!mounted) return;
    setState(() => _resuming = false);
    if (_liveSerial != serial) return;
    final device = devices
        .where((candidate) => candidate.serial == serial && candidate.isReady)
        .firstOrNull;
    // Unplugged while the pane was away. The ordinary "pick a device" state —
    // not an error, and not a spinner with nothing behind it.
    if (device == null) {
      await _stopAndRebuild();
      return;
    }
    await _startStream(device);
  }

  /// A minimised window is not a stalled player; `inactive` is deliberately
  /// still watching — an unfocused window is one the user can still see.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _session?.setWatched(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  /// A real teardown, not `setWatched`: a pane switched away from is worth no
  /// encode on the phone. [androidLiveViewProvider] remembers to come back.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _disposeSession();
    _releaseHeldPicture();
    super.dispose();
  }

  /// Tears the running session down, leaving [_liveSerial] alone — a restart
  /// or a switch is still "on". [retainPicture] keeps the frame, never input.
  Future<void> _disposeSession({bool retainPicture = false}) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final session = _session;
    final player = _player;
    final video = _video;
    final health = _healthSubscription;
    final clipboard = _clipboard;
    // Before anything is torn down: a registration outliving its session would
    // hand the next picker a `setQuiet` for a socket that is already gone.
    _releaseQuiet?.call();
    _releaseQuiet = null;
    _healthSubscription = null;
    _session = null;
    _player = null;
    _video = null;
    _sink = null;
    _keyboardSink = null;
    _clipboard = null;
    _health = null;
    await health?.cancel();
    await clipboard?.dispose();
    await session?.stop();
    if (retainPicture && player != null) {
      await _releaseHeldPicture();
      _heldPlayer = player;
      _heldVideo = video;
      return;
    }
    await player?.dispose();
  }

  /// Lets go of the held frame. Idempotent: every teardown path comes here.
  Future<void> _releaseHeldPicture() async {
    final player = _heldPlayer;
    _heldPlayer = null;
    _heldVideo = null;
    await player?.dispose();
  }

  /// Turns the live view off entirely: no session, and no device it is for.
  Future<void> _stopStream() async {
    _liveSerial = null;
    _holdingPicture = false;
    await _disposeSession();
    await _releaseHeldPicture();
  }

  /// Keeps the live view on the *explicit* [selectedDeviceSerialProvider], not
  /// the derived one, whose "only ready device" default would move it alone.
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
        _restarts.reset();
        unawaited(_startStream(next.device!));
    }
  }

  Future<void> _stopAndRebuild() async {
    await _stopStream();
    if (mounted) setState(() {});
  }

  /// Restarts the live view for the device it is already showing.
  Future<void> _restartStream({bool manual = true}) async {
    final serial = _liveSerial ?? ref.read(selectedDeviceProvider)?.serial;
    final device = ref
        .read(devicesProvider)
        .asData
        ?.value
        .where((candidate) => candidate.serial == serial)
        .firstOrNull;
    if (device == null) return;
    if (manual) _restarts.reset();
    await _startStream(device);
  }

  /// Reacts to the stream's opinion of itself. Restarting is
  /// [StreamRestartPolicy]'s call: a static screen is not an unhealthy stream.
  void _onHealth(DeviceStreamHealth health) {
    if (!mounted) return;
    setState(() => _health = health);
    if (_reconnectTimer != null || _starting) return;
    final session = _session;
    final step = _restarts.onHealth(
      health,
      DateTime.now(),
      canResetVideo: session?.control != null,
    );
    switch (step.action) {
      case StreamRecovery.none:
        return;
      case StreamRecovery.resetVideo:
        // The cheapest rung: a fresh keyframe over a socket already healthy.
        final sent = session?.requestVideoReset() ?? false;
        _log.info(
          sent
              ? 'Asked $_liveSerial for a video reset: ${health.detail}'
              : 'No control socket to ask $_liveSerial for a video reset.',
        );
      case StreamRecovery.reattachPlayer:
        _log.warning(
          'Re-attaching the live view player on $_liveSerial: ${health.detail}',
        );
        unawaited(_reattachPlayer());
      case StreamRecovery.restart:
        // With the reason: the old loop logged only that the stream stopped.
        _log.warning(
          'Restarting the live view on $_liveSerial in '
          '${step.delay.inSeconds}s (attempt ${_restarts.attempt}): '
          '${health.detail}',
        );
        _reconnectTimer = Timer(step.delay, () {
          _reconnectTimer = null;
          if (mounted) _restartStream(manual: false);
        });
    }
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
    // Starting the live view *is* choosing a device: pinning it here keeps the
    // toolbar, picture, gestures and hardware keys from disagreeing.
    ref.read(selectedDeviceSerialProvider.notifier).select(device.serial);
    // Only for the device already on screen. Another device's last frame is
    // not a stale picture of this one — it is the wrong phone.
    final retainPicture = _session?.serial == device.serial && _player != null;
    // A hold that is not being renewed belongs to a stream that is not coming
    // back; its frame would be labelled with the wrong device's name.
    if (!retainPicture) unawaited(_releaseHeldPicture());
    setState(() {
      _starting = true;
      _holdingPicture = retainPicture;
      _streamError = null;
    });
    await _disposeSession(retainPicture: retainPicture);
    try {
      final session = await service.start(device.serial);
      if (!mounted || token != _startToken) {
        await session.stop();
        return;
      }
      // A player that fails to open leaves the session to be stopped here, or
      // every retry leaks an `app_process`, a forward and a loopback server.
      final opened = await openOrRelease(
        open: () => _openPlayer(session.url),
        release: session.stop,
      );
      final player = opened.player;
      final controller = opened.controller;
      if (!mounted || token != _startToken) {
        await session.stop();
        await player.dispose();
        return;
      }
      _healthSubscription = session.health.listen(_onHealth);
      // From the moment there is a session, not from the moment the pane is
      // looked at: the pickers are elsewhere in the app, and it keeps working.
      _releaseQuiet = PickerQuiet.instance.register(session.setQuiet);
      final sink = _controlSink(session);
      final control = session.control;
      setState(() {
        _session = session;
        _player = player;
        _video = controller;
        _starting = false;
        _holdingPicture = false;
        _health = null;
        _sink = sink;
        // Built eagerly: the device pushes its clipboard as an event, so a
        // listener attached on first press would have missed everything.
        _clipboard = control == null
            ? null
            : DeviceClipboardBridge(channel: control);
        // No screen size needed, unlike a gesture waiting on `wm size`.
        _keyboardSink = _keyboardSinkFor(session);
      });
      // Offered on every start, not only when a recording is running: only
      // the recorder knows whether one is open and wants the frames.
      ref
          .read(deviceRecordingProvider.notifier)
          .offerLiveView(
            LiveViewRecordingSource(
              target: AndroidTarget(device),
              openTransportStream: session.openTransportStream,
              openAccessUnits: session.openAccessUnits,
              geometryChanges: session.videoSizeChanges,
            ),
          );
      // After the frame that shows the new picture, never before: disposing a
      // player whose texture is still on screen is how a live view flashes.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_releaseHeldPicture()),
      );
      // The adb fallback needs a `wm size` round trip; fetched off the start
      // path so a slow answer delays gestures rather than the picture.
      if (sink == null) unawaited(_useAdbSink(session.serial));
    } catch (error) {
      if (!mounted || token != _startToken) return;
      unawaited(_releaseHeldPicture());
      setState(() {
        _starting = false;
        _holdingPicture = false;
        _liveSerial = null;
        _streamError = '$error';
      });
    }
  }

  /// Builds a player pointed at [url] and waits for it to open.
  Future<({Player player, VideoController controller})> _openPlayer(
    Uri url,
  ) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        // A live view wants the newest frame, not a smooth buffer.
        bufferSize: 256 * 1024,
        logLevel: MPVLogLevel.error,
        protocolWhitelist: ['file', 'tcp', 'http'],
      ),
    );
    return openOrRelease(
      open: () async {
        final native = player.platform as NativePlayer;
        // libmpv buffers for smoothness; these make it a monitor. `setProperty`
        // swallows libmpv's return code — verify a change by reading it back.
        await configureDeviceLivePlayer(native.setProperty);
        final controller = VideoController(player);
        await player.open(Media(url.toString()));
        return (player: player, controller: controller);
      },
      release: player.dispose,
    );
  }

  /// A failed `adb shell input` is a fact about the device, said once here
  /// rather than discarded — the gesture already went nowhere.
  void _onAdbInputError(Object error) {
    _log.warning('adb input on $_liveSerial failed: $error');
  }

  /// Rebuilds the player against the stream it is already reading: the middle
  /// recovery rung, fixing a wedged player without touching server or sockets.
  Future<void> _reattachPlayer() async {
    final session = _session;
    if (session == null || _starting) return;
    final token = ++_startToken;
    await _releaseHeldPicture();
    if (!mounted || token != _startToken) return;
    setState(() {
      _heldPlayer = _player;
      _heldVideo = _video;
      _player = null;
      _video = null;
      _starting = true;
      _holdingPicture = _heldVideo != null;
    });
    try {
      final opened = await _openPlayer(session.url);
      if (!mounted || token != _startToken || _session != session) {
        await opened.player.dispose();
        return;
      }
      setState(() {
        _player = opened.player;
        _video = opened.controller;
        _starting = false;
        _holdingPicture = false;
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_releaseHeldPicture()),
      );
    } catch (error) {
      _log.warning('Re-attaching the live view player failed: $error');
      if (!mounted || token != _startToken) return;
      // Leave the held frame up and let the ladder move on to a full restart;
      // a failed re-attach is not a reason to blank the pane.
      setState(() => _starting = false);
    }
  }

  /// The control-socket gesture sink, or `null` when there is none and the adb
  /// fallback is needed — a drag that jumps on release is a different product.
  DeviceGestureSink? _controlSink(DeviceStreamSession session) {
    final control = session.control;
    if (control == null) return null;
    return _observed(
      session,
      ScrcpyGestureSink(
        connection: control,
        videoSize: () => session.videoSize,
        onDropped: _onControlDropped,
      ),
    );
  }

  /// Every sink goes through here: the stream cannot tell a static screen from
  /// a device that stopped answering unless it knows input is being sent.
  DeviceGestureSink _observed(
    DeviceStreamSession session,
    DeviceGestureSink sink,
  ) => ObservedGestureSink(sink, onInput: session.noteInput);

  DeviceKeyboardSink _observedKeys(
    DeviceStreamSession session,
    DeviceKeyboardSink sink,
  ) => ObservedKeyboardSink(sink, onInput: session.noteInput);

  /// Where keystrokes for [session] go: the control socket, else `adb shell
  /// input`, and `null` only when there is no adb either.
  DeviceKeyboardSink? _keyboardSinkFor(DeviceStreamSession session) {
    final control = session.control;
    if (control != null) {
      return _observedKeys(
        session,
        ScrcpyKeyboardSink(connection: control, onDropped: _onControlDropped),
      );
    }
    final adb = ref.read(adbServiceProvider);
    if (adb == null) return null;
    return _observedKeys(
      session,
      AdbKeyboardSink(
        adb: adb,
        serial: session.serial,
        onError: _onAdbInputError,
      ),
    );
  }

  /// Installs the `adb shell input` gesture sink for [serial] — sized by the
  /// streamed device, since the wrong resolution silently misplaces a tap.
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
    final session = _session;
    if (_liveSerial != serial || session?.serial != serial) return;
    setState(
      () => _sink = _observed(
        session!,
        AdbGestureSink(
          adb: adb,
          serial: serial,
          screen: screen,
          onError: _onAdbInputError,
        ),
      ),
    );
  }

  /// The control socket went away mid-session. Fall back rather than going mute.
  void _onControlDropped() {
    final serial = _liveSerial;
    final session = _session;
    if (!mounted || serial == null || session == null) return;
    final adb = ref.read(adbServiceProvider);
    // The clipboard has no second transport, so it goes rather than degrading.
    final clipboard = _clipboard;
    if (clipboard != null && !clipboard.isOpen) {
      _clipboard = null;
      unawaited(clipboard.dispose());
    }
    // Keyed on the transport, not the class: every sink is wrapped now, so
    // `is AdbKeyboardSink` would reinstall the fallback on every drop.
    if (adb != null &&
        _keyboardSink?.transport != DeviceKeyboardTransport.adbInput) {
      // The keyboard needs no screen size, so it falls back immediately.
      setState(
        () => _keyboardSink = _observedKeys(
          session,
          AdbKeyboardSink(adb: adb, serial: serial, onError: _onAdbInputError),
        ),
      );
    }
    if (_sink?.transport == DeviceGestureTransport.adbInput) return;
    unawaited(_useAdbSink(serial));
  }
}
