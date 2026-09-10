// **The live view's session** — everything the pane does that is not drawing.
//
// Starting and stopping a stream, opening and re-attaching the player, holding
// the previous picture across a restart, the health subscription and the
// restart policy, the gesture, keyboard and clipboard sinks with their adb
// fallback, and the resume that survives the side panel unmounting the pane.
//
// A mixin because a class cannot be split across parts and `build` reads the
// fields this owns; `on WidgetsBindingObserver` because the lifecycle callback
// below is that mixin's, and applying this after it is what keeps the override
// order the class had.
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

mixin _DeviceLiveStream
    on ConsumerState<DevicePane>, WidgetsBindingObserver {
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
  ///
  /// It is stored in [androidLiveViewProvider] rather than in this `State`,
  /// because the side panel unmounts the pane whenever it switches surface and
  /// the flag has to survive that. Every write below is inside — or
  /// immediately followed by — a `setState`, which is why reading it does not
  /// need to watch.
  String? get _liveSerial => ref.read(androidLiveViewProvider);
  set _liveSerial(String? serial) =>
      ref.read(androidLiveViewProvider.notifier).select(serial);

  /// A live view being brought back after a remount, before the device list has
  /// answered. Kept apart from [_starting], whose job is to refuse a second
  /// `_startStream` for the device already starting — a resume has to be let
  /// through it.
  bool _resuming = false;

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

  /// The device's clipboard, over the same control socket the sinks use.
  ///
  /// `null` when there is no control socket, and there is deliberately **no adb
  /// fallback** — unlike input, where `adb shell input` is a worse but real
  /// second transport. adb has no clipboard verb at all (see
  /// `DeviceClipboardBridge`'s measurements), so with no socket the honest
  /// answer is that the clipboard cannot be reached, and the control says so
  /// rather than offering a button that does nothing.
  DeviceClipboardBridge? _clipboard;

  /// The previous session's player, kept alive across a restart so the last
  /// frame it decoded stays on screen instead of the picture going blank.
  ///
  /// It is a *held* picture, never a live one: whenever this is what is on
  /// screen, [StreamReconnectingOverlay] is over it saying so. Disposed as soon
  /// as the new stream has a picture of its own.
  Player? _heldPlayer;
  VideoController? _heldVideo;

  /// Whether the picture on screen belongs to the session being replaced.
  ///
  /// Held across the whole restart, not derived from which field the controller
  /// is in: the picture is the outgoing session's from the moment the restart
  /// begins, and it is only [_heldVideo] for the part of that after the old
  /// session has been torn down.
  bool _holdingPicture = false;

  Timer? _reconnectTimer;

  /// Lets go of this session's registration with [PickerQuiet].
  ///
  /// The live view is the one thing on this pane that works on the isolate
  /// whether or not anybody is touching it, and a host file dialog is built on
  /// that same thread — see `core/util/file_picking.dart`. Registering the
  /// *session* rather than the pane is deliberate: the picker the user opens is
  /// rarely on this surface (Settings, a new project, an SSH key), and the rule
  /// is about the isolate, not about which pane is in front.
  VoidCallback? _releaseQuiet;

  /// When an unwell stream is worth restarting, and how long to wait first.
  final StreamRestartPolicy _restarts = StreamRestartPolicy();

  static final AppLogger _log = AppLogger.named('device-stream');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The side panel unmounts this pane every time it switches surface, and
    // [dispose] takes the session down with it. What survived is the intent;
    // this is what acts on it.
    final serial = ref.read(androidLiveViewProvider);
    if (serial != null) {
      // From the first frame, so the pane does not flash "pick a device" on
      // its way back to a live view it is about to have.
      _resuming = true;
      unawaited(_resumeLiveView(serial));
    }
  }

  /// Puts the live view back on the device it was on before the unmount.
  ///
  /// The device list is awaited rather than read: it outlives the pane, but a
  /// refresh may be in flight, and a list still loading reads as the same empty
  /// list as a phone that has been unplugged.
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

  /// A minimised window is not a stalled player.
  ///
  /// `inactive` is deliberately still watching: an unfocused window is one the
  /// user can see perfectly well, and often the whole point of a live view.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _session?.setWatched(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  /// A real teardown, not [DeviceStreamSession.setWatched] on a retained
  /// session. `setWatched` only stops the watchdog reading silence as a stall;
  /// it does not stop one frame being encoded on the phone, pushed over the
  /// socket and decoded by libmpv. A pane the user switched away from is worth
  /// no battery on their handset and no decode on the host — so the session
  /// goes, and [androidLiveViewProvider] remembers that it should come back.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _disposeSession();
    _releaseHeldPicture();
    super.dispose();
  }

  /// Tears the running session down. Leaves [_liveSerial] alone: this is what a
  /// restart or a device switch uses, and both are still "the live view is on".
  ///
  /// With [retainPicture] the player outlives the session it was showing, so a
  /// restart of the same device replaces the picture rather than removing it.
  /// Everything that carries input — the sockets, the sinks, the keyboard — is
  /// torn down either way: only the frame is kept.
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

  /// Lets go of the held frame. Idempotent: a restart, a stop, a device switch
  /// and `dispose` all pass through here.
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
        _restarts.reset();
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
    if (manual) _restarts.reset();
    await _startStream(device);
  }

  /// Reacts to the stream's opinion of itself.
  ///
  /// **Restarting is [StreamRestartPolicy]'s decision, not this method's.** It
  /// used to be "anything that is not healthy", which included a device sitting
  /// on a static screen, and the live view spent nine minutes restarting a
  /// phone nobody was touching.
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
        // The cheapest rung: the device is asked for a fresh keyframe over the
        // control socket we already know is healthy. Nothing is torn down, so
        // there is nothing for the user to see except the picture resuming.
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
        // Said out loud, because the log of the restart loop recorded only that
        // the stream had stopped — never why, which is what made it a mystery.
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
    // Starting the live view *is* choosing a device. Pinning it here means the
    // toolbar, the picture, the gestures and the hardware keys cannot disagree
    // about which device the pane is about.
    ref.read(selectedDeviceSerialProvider.notifier).select(device.serial);
    // Only for the device already on screen. Another device's last frame is
    // not a stale picture of this one — it is the wrong phone.
    final retainPicture = _session?.serial == device.serial && _player != null;
    // A hold that is not being renewed belongs to a stream that is not coming
    // back — another device, or a start that was overtaken. Only `_starting`
    // keeps it off the screen, and that is too thin a thread for a frame that
    // would be labelled with the wrong device's name.
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
      final opened = await _openPlayer(session.url);
      final player = opened.player;
      final controller = opened.controller;
      if (!mounted || token != _startToken) {
        await session.stop();
        await player.dispose();
        return;
      }
      _healthSubscription = session.health.listen(_onHealth);
      // From the moment there is a session, not from the moment the pane is
      // looked at: the stream keeps working while the user is somewhere else in
      // the app, and that is exactly where the pickers are.
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
        // Built here rather than lazily so the device's pushed clipboard is
        // being listened for from the moment the stream is up: it arrives as
        // an event, and a listener attached only when the user first presses
        // the button would have missed everything before that.
        _clipboard = control == null
            ? null
            : DeviceClipboardBridge(channel: control);
        // The keyboard needs no screen size, so it is available immediately in
        // either transport — a gesture has to wait for `wm size`, a keystroke
        // does not.
        _keyboardSink = _keyboardSinkFor(session);
      });
      // A recording that lost its frames when this pane last unmounted picks
      // them up here. Offered on every start, not only when one is running:
      // the recorder is what decides whether it wants them, and it is the only
      // thing that knows whether a recording is open.
      ref.read(deviceRecordingProvider.notifier).offerLiveView(
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
      // No control socket: the adb fallback needs the device's screen size,
      // which is a round trip. Fetched off the start path so a slow `wm size`
      // delays gestures rather than the picture.
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
  ///
  /// Extracted because re-attaching the player is a recovery step of its own:
  /// the same player, the same properties, a second time, against a stream that
  /// never went away.
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
    final native = player.platform as NativePlayer;
    // libmpv defaults to buffering for smooth playback; these make it behave
    // like a monitor. `setProperty` swallows libmpv's return code, so these
    // were verified by reading them back: `profile=low-latency` really is
    // applied (`cache-pause=no`, `video-latency-hacks=yes` and
    // `stream-buffer-size=4096` are the profile's values, not the defaults).
    await configureDeviceLivePlayer(native.setProperty);
    final controller = VideoController(player);
    await player.open(Media(url.toString()));
    return (player: player, controller: controller);
  }

  /// Rebuilds the player against the stream it is already reading.
  ///
  /// The middle rung of the recovery ladder, and the one that fixes a wedged
  /// player without costing anything: the scrcpy server, the tunnel, the
  /// sockets and the session all stay exactly as they are, and the media server
  /// hands the new viewer a fresh muxer, fresh tables and the cached keyframe.
  /// The old picture stays on screen — behind [HeldPicture] — until the new one
  /// has opened, so the pane never goes blank for it.
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

  /// The control-socket gesture sink for a session, or `null` when the session
  /// has no control socket and the adb fallback is needed.
  ///
  /// The two are not equivalent and the pane says which is in use, because a
  /// drag that tracks the finger and a drag that jumps on release are different
  /// products.
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

  /// Every sink the pane hands out goes through here.
  ///
  /// The stream cannot tell a device with nothing to draw from one that has
  /// stopped answering unless it knows the user is asking — and the live view
  /// is the only place that knows. Wrapping at the one place sinks are built
  /// means no transport can forget to say so.
  DeviceGestureSink _observed(
    DeviceStreamSession session,
    DeviceGestureSink sink,
  ) => ObservedGestureSink(sink, onInput: session.noteInput);

  DeviceKeyboardSink _observedKeys(
    DeviceStreamSession session,
    DeviceKeyboardSink sink,
  ) => ObservedKeyboardSink(sink, onInput: session.noteInput);

  /// Where keystrokes for [session] go.
  ///
  /// Unlike gestures this never returns `null` for want of a screen size: the
  /// control socket if there is one, `adb shell input` if there is not, and
  /// `null` only when there is no adb either — which the pane states rather
  /// than swallowing keys.
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
      AdbKeyboardSink(adb: adb, serial: session.serial),
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
    final session = _session;
    if (_liveSerial != serial || session?.serial != serial) return;
    setState(
      () => _sink = _observed(
        session!,
        AdbGestureSink(adb: adb, serial: serial, screen: screen),
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
    // Kept as a fact the controls can read: the button then explains that the
    // socket has closed instead of failing on every press.
    final clipboard = _clipboard;
    if (clipboard != null && !clipboard.isOpen) {
      _clipboard = null;
      unawaited(clipboard.dispose());
    }
    // Keyed on the transport rather than the class: every sink is wrapped for
    // input observation now, so `is AdbKeyboardSink` would never be true again
    // and the fallback would reinstall itself on every dropped event.
    if (adb != null &&
        _keyboardSink?.transport != DeviceKeyboardTransport.adbInput) {
      // The keyboard falls back on its own: it does not need the screen size
      // the gesture sink is about to go and fetch.
      setState(
        () => _keyboardSink = _observedKeys(
          session,
          AdbKeyboardSink(adb: adb, serial: serial),
        ),
      );
    }
    if (_sink?.transport == DeviceGestureTransport.adbInput) return;
    unawaited(_useAdbSink(serial));
  }
}
