/// Moving text between this computer's and an Android device's clipboard over
/// scrcpy's control socket: adb has none, so this needs the live view running.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../devices.dart';

/// How long the device gets to answer before we say it did not. Generous: the
/// round trip is sub-millisecond, so anything near this bound means wedged.
const Duration kDeviceClipboardTimeout = Duration(seconds: 3);

/// One device's clipboard, over one scrcpy control socket. Created and
/// disposed with the live view; one whose socket closed refuses, safely.
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

  /// Sequence numbers start at 1: 0 is `SEQUENCE_INVALID`, which the server
  /// reads as "do not acknowledge", so a zero write could never be confirmed.
  int _nextSequence = 1;

  /// Emits whenever the device's clipboard is observed to have changed — the
  /// event only: a stream of clipboard contents is a stream of user data.
  Stream<void> get changes => _changes.stream;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// The most recent thing known about the device's clipboard, never `null`:
  /// unchecked until asked, so "not asked" cannot be drawn as "empty".
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

  /// Puts this computer's clipboard onto the device's: one `SET_CLIPBOARD`,
  /// then a wait for the acknowledgement carrying that sequence.
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

  /// Puts [text] on the device's clipboard. A write sent and not acknowledged
  /// is neither a success nor a failure, and the outcome says exactly that.
  Future<DeviceClipboardWrite> writeToDevice(String text) async {
    if (refusal case final reason?) {
      return DeviceClipboardWrite.refused(reason);
    }
    if (text.length > kScrcpyClipboardTextMaxBytes) {
      // Cheap pre-check on characters; the encoder counts bytes. Both refuse
      // rather than truncate — an over-long message desynchronises the socket.
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

  /// Asks the device for its clipboard. One that does not answer is
  /// [DeviceClipboardOutcome.unavailable] and never empty — that is the point.
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

  /// Reads the device's clipboard and puts it on this computer's — nothing is
  /// written here unless the device actually answered with text.
  Future<DeviceClipboardRead> copyDeviceToHost() async {
    final read = await readFromDevice();
    if (read.hasText) await host.writeText(read.text!);
    return read;
  }

  /// Puts the last clipboard the device *pushed* onto this computer's: no
  /// round trip. Refuses when nothing was observed, which is not "empty".
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

  /// Stops reading the socket. In-flight reads are left to time out rather
  /// than failed: the caller's contract is a [DeviceClipboardRead], not a throw.
  Future<void> dispose() async {
    await _subscription.cancel();
    await _changes.close();
  }
}
