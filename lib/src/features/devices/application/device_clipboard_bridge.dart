/// Moving text between this computer's clipboard and an Android device's.
///
/// ## What makes this possible at all, and what it costs
///
/// **There is no adb clipboard verb.** Measured 2026-09-07 on the cabled
/// OnePlus CPH1989 (Android 11 / API 30):
///
/// * `adb shell cmd clipboard` → `No shell command implementation.` The
///   `clipboard` service is in `service list` and in `cmd -l`, and it answers
///   neither.
/// * `adb shell dumpsys clipboard` → **zero lines**. Nothing to read there.
/// * `adb shell service call clipboard …` cannot be made to work in either
///   direction: `service`'s own usage lists `i32 i64 f d s16 null fd nfd afd`
///   as the arguments it can marshal, and `setPrimaryClip` takes a `ClipData`
///   parcelable — not in that list. `getPrimaryClip` *returns* one, which
///   `service` prints as a raw parcel hex dump, and its transaction number
///   moves between Android versions.
///
/// So the transport is **scrcpy's control socket**, which this app already
/// opens for touch and keyboard input, and the reason it can read a clipboard
/// that adb cannot is a permission:
///
/// ```txt
/// $ adb shell dumpsys package com.android.shell | grep -i clip
///   android.permission.READ_CLIPBOARD_IN_BACKGROUND: granted=true
/// ```
///
/// scrcpy-server runs as the shell uid and tells the framework it is
/// `com.android.shell` (`FakeContext.PACKAGE_NAME` in the deployed jar), so its
/// `getPrimaryClip`/`setPrimaryClip` are exempt from the Android 10+ rule
/// confining clipboard access to the foreground app or the active IME. That
/// exemption is a **fact about the device**, not about this app: it is a
/// signature permission and a vendor build is free not to grant it. Which is
/// why every answer here is a [DeviceClipboardRead] and never a bare `String?`
/// — a device that refuses must not be reported as a device with nothing
/// copied.
///
/// ## The two costs, stated plainly
///
/// * **It needs the live view running.** The control socket is opened with the
///   stream; with no stream there is no socket, and this bridge refuses in
///   words rather than silently doing nothing. A control-only scrcpy server
///   (`video=false control=true`) would lift that and is the obvious next step;
///   it is a second server lifecycle to own, so it is written down rather than
///   built.
/// * **It spawns nothing.** Not one process per sync, not one per poll — the
///   socket is already open, so a read is one `send` and a wait, and a write is
///   the same. `processSpawnsOnThisIsolate` does not move for either.
///
/// ## Nothing polls
///
/// §19's third rule, and here it costs nothing to keep: the device *pushes*.
/// scrcpy-server registers an `OnPrimaryClipChangedListener` when
/// `clipboardAutosync` is on — the jar's `Options` constructor defaults it to
/// true and this app does not pass the option — so a copy on the phone arrives
/// as a `TYPE_CLIPBOARD` message with no round trip and no timer. [latest] is
/// that event, with its age. Writing it onto *this* computer's clipboard still
/// takes an explicit action: a background process replacing what the user
/// copied thirty seconds ago is not a sync, it is a theft.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../core/clipboard/host_clipboard.dart';
import 'package:karmashala_devices/devices.dart';

/// How long to wait for the device to answer before saying it did not.
///
/// Generous on purpose. The round trip is a socket write, a binder call and a
/// socket read — sub-millisecond when the device is well — so anything near
/// this bound means the device is busy or the server is wedged, and the answer
/// then is [DeviceClipboardOutcome.unavailable] rather than a longer wait.
const Duration kDeviceClipboardTimeout = Duration(seconds: 3);

/// One device's clipboard, over one scrcpy control socket.
///
/// Created and disposed with the live view, like the gesture and keyboard
/// sinks next door. Holding one whose socket has closed is safe: every method
/// checks and refuses.
class DeviceClipboardBridge {
  DeviceClipboardBridge({
    required this.channel,
    this.host = const PlatformHostClipboard(),
    this.timeout = kDeviceClipboardTimeout,
  }) {
    _subscription = channel.replies.listen(_onBytes);
  }

  /// The live view's control socket. Public because this object *is* the
  /// clipboard half of that socket and hiding it buys nothing.
  final ScrcpyControlChannel channel;

  /// This computer's clipboard, behind its seam — see `host_clipboard.dart`.
  final HostClipboard host;

  /// How long a device gets to answer. See [kDeviceClipboardTimeout].
  final Duration timeout;

  late final StreamSubscription<Uint8List> _subscription;
  final ScrcpyDeviceMessageParser _parser = ScrcpyDeviceMessageParser();

  /// Waiters for the next clipboard the device sends.
  final List<Completer<String>> _textWaiters = [];

  /// Waiters for an acknowledgement, keyed by the sequence they sent.
  final Map<int, Completer<void>> _ackWaiters = {};

  /// Sequence numbers start at 1: `ControlMessage.SEQUENCE_INVALID` is 0, which
  /// the server reads as "do not acknowledge", so a write numbered zero could
  /// never be confirmed.
  int _nextSequence = 1;

  /// Emits whenever the device's clipboard is observed to have changed.
  ///
  /// The *event*, for a pane that wants to redraw its label. Never the text —
  /// a stream of clipboard contents is a stream of user data through every
  /// listener that ever gets added.
  Stream<void> get changes => _changes.stream;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// The most recent thing known about the device's clipboard.
  ///
  /// [DeviceClipboardRead.unchecked] until something is. Never `null`, so the
  /// pane cannot accidentally draw "empty" for "not asked".
  DeviceClipboardRead get latest => _latest;
  DeviceClipboardRead _latest = DeviceClipboardRead.unchecked;

  /// Whether the socket this bridge speaks over is still up.
  bool get isOpen => channel.isOpen && !_parser.desynchronised;

  /// Why this bridge cannot be used, or null when it can.
  String? get refusal {
    if (_parser.desynchronised) {
      return 'The control socket sent a message this build cannot read, so it '
          'is no longer being read from. Restart the live view.';
    }
    if (!channel.isOpen) {
      return 'The live view\'s control socket has closed, and the clipboard '
          'travels over it. Restart the live view.';
    }
    return null;
  }

  /// Puts this computer's clipboard onto the device's.
  ///
  /// Reads the host clipboard through the seam that survives a Windows
  /// `OpenClipboard` failure, then sends one `SET_CLIPBOARD` and waits for the
  /// acknowledgement carrying that sequence.
  Future<DeviceClipboardWrite> copyHostToDevice() async {
    if (refusal case final reason?) {
      return DeviceClipboardWrite.refused(reason);
    }
    final read = await host.readText();
    return switch (read.outcome) {
      HostClipboardOutcome.unavailable => DeviceClipboardWrite.refused(
        read.reason!,
      ),
      HostClipboardOutcome.empty => const DeviceClipboardWrite.refused(
        'There is no text on this computer\'s clipboard to copy.',
      ),
      HostClipboardOutcome.text => await writeToDevice(read.text!),
    };
  }

  /// Puts [text] on the device's clipboard.
  ///
  /// Three outcomes, and the middle one is the point: a write that was sent and
  /// not acknowledged is neither a success nor a failure, and
  /// [DeviceClipboardWriteOutcome.unacknowledged] says so rather than choosing
  /// a side.
  Future<DeviceClipboardWrite> writeToDevice(String text) async {
    if (refusal case final reason?) {
      return DeviceClipboardWrite.refused(reason);
    }
    if (text.length > kScrcpyClipboardTextMaxBytes) {
      // Cheap pre-check on characters; the encoder counts bytes and is the
      // authority. Both refuse rather than truncate — an over-long message
      // desynchronises the socket for good.
      return const DeviceClipboardWrite.refused(
        'That is too much text for one clipboard message.',
      );
    }
    final sequence = _nextSequence++;
    final message = ScrcpySetClipboardMessage(sequence: sequence, text: text);
    final Completer<void> ack = Completer<void>();
    _ackWaiters[sequence] = ack;
    try {
      if (!channel.send(message.encode())) {
        return const DeviceClipboardWrite.refused(
          'The control socket would not take the message. Restart the live '
          'view.',
        );
      }
      await ack.future.timeout(timeout);
      return const DeviceClipboardWrite.acknowledged();
    } on ArgumentError {
      return const DeviceClipboardWrite.refused(
        'That is too much text for one clipboard message.',
      );
    } on TimeoutException {
      return const DeviceClipboardWrite.unacknowledged(
        'The text was sent and the device did not confirm it. Its clipboard '
        'may or may not have changed — check on the device rather than '
        'trusting this.',
      );
    } finally {
      _ackWaiters.remove(sequence);
    }
  }

  /// Asks the device for its clipboard.
  ///
  /// A device that does not answer produces
  /// [DeviceClipboardOutcome.unavailable]. It is never reported as empty: the
  /// whole feature turns on that distinction, because "empty" tells the user to
  /// copy something again and the thing that is actually wrong is elsewhere.
  Future<DeviceClipboardRead> readFromDevice() async {
    if (refusal case final reason?) {
      return _record(DeviceClipboardRead.unavailable(reason));
    }
    final Completer<String> waiter = Completer<String>();
    _textWaiters.add(waiter);
    try {
      if (!channel.send(encodeGetClipboard())) {
        return _record(
          DeviceClipboardRead.unavailable(
            'The control socket would not take the request. Restart the live '
            'view.',
          ),
        );
      }
      final text = await waiter.future.timeout(timeout);
      return _record(
        DeviceClipboardRead.text(
          text,
          source: DeviceClipboardSource.requested,
        ),
      );
    } on TimeoutException {
      return _record(
        DeviceClipboardRead.unavailable(
          'The device did not answer with its clipboard. On Android 10 and '
          'later only the foreground app, the active keyboard, or a process '
          'holding READ_CLIPBOARD_IN_BACKGROUND may read it — this build asks '
          'through scrcpy-server, which runs as com.android.shell and '
          'normally holds that permission. A device whose build does not '
          'grant it cannot be read from here at all. What is on the '
          'clipboard is unknown; it is not empty.',
        ),
      );
    } finally {
      _textWaiters.remove(waiter);
    }
  }

  /// Reads the device's clipboard and puts it on this computer's.
  ///
  /// Nothing is written to the host clipboard unless the device actually
  /// answered with text: an unreadable device must not clear what the user had
  /// copied here.
  Future<DeviceClipboardRead> copyDeviceToHost() async {
    final read = await readFromDevice();
    if (read.hasText) await host.writeText(read.text!);
    return read;
  }

  /// Puts the last clipboard the device *pushed* onto this computer's.
  ///
  /// The zero-round-trip path: the device already told us, unprompted, when the
  /// user copied on the phone. Refuses when nothing has been observed, which is
  /// the state that must never be drawn as an empty clipboard.
  Future<DeviceClipboardRead> copyLatestToHost() async {
    final read = _latest;
    if (read.hasText) await host.writeText(read.text!);
    return read;
  }

  DeviceClipboardRead _record(DeviceClipboardRead read) {
    _latest = read;
    return read;
  }

  void _onBytes(List<int> bytes) {
    for (final message in _parser.add(bytes)) {
      switch (message) {
        case ScrcpyClipboardText(:final text):
          // A push and a reply are the same bytes. If somebody is waiting,
          // this is their answer; otherwise the device volunteered it.
          if (_textWaiters.isNotEmpty) {
            final waiter = _textWaiters.removeAt(0);
            if (!waiter.isCompleted) waiter.complete(text);
          } else {
            _record(
              DeviceClipboardRead.text(
                text,
                source: DeviceClipboardSource.pushedByDevice,
              ),
            );
            if (!_changes.isClosed) _changes.add(null);
          }
        case ScrcpyClipboardAck(:final sequence):
          final waiter = _ackWaiters.remove(sequence);
          if (waiter != null && !waiter.isCompleted) waiter.complete();
        case ScrcpyUhidOutput():
          // Nothing creates a UHID device. Parsed only so the message after it
          // is found in the right place.
          break;
        case ScrcpyUnknownDeviceMessage():
          // The parser has stopped; [refusal] now explains why. Anything still
          // waiting will time out into an honest "unavailable".
          break;
      }
    }
  }

  /// Stops reading the socket. In-flight reads are **left to time out** rather
  /// than failed: a `completeError` here would surface as an exception out of
  /// `readFromDevice`, and its caller's contract is a
  /// [DeviceClipboardRead] — an honest `unavailable` a moment later beats a
  /// throw the pane has to guess the wording for.
  Future<void> dispose() async {
    await _subscription.cancel();
    await _changes.close();
  }
}
