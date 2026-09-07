import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/process_spawn.dart';
import 'package:karmashala/src/features/devices/application/device_clipboard_bridge.dart';
import 'package:karmashala/src/features/devices/domain/device_clipboard.dart';

import 'fake_scrcpy_control_channel.dart';

/// The clipboard bridge: sequence matching, the three-valued read, and the one
/// distinction the whole feature turns on — a clipboard that could not be read
/// is never reported as an empty clipboard.
///
/// Timeouts here are zero, not short. Nothing asserts on how long anything
/// takes; what is asserted is *which outcome* a device that never answers
/// produces.
void main() {
  late FakeScrcpyControlChannel channel;
  late FakeHostClipboard host;

  DeviceClipboardBridge build({Duration? timeout}) => DeviceClipboardBridge(
    channel: channel,
    host: host,
    timeout: timeout ?? Duration.zero,
  );

  setUp(() {
    channel = FakeScrcpyControlChannel();
    host = FakeHostClipboard();
  });

  tearDown(() => channel.dispose());

  group('before anything has been read', () {
    test('the reading is not "empty" — it is "not asked"', () {
      final bridge = build();
      expect(bridge.latest.outcome, DeviceClipboardOutcome.unavailable);
      expect(bridge.latest.source, DeviceClipboardSource.none);
      expect(bridge.latest.wasObserved, isFalse);
      expect(bridge.latest.reason, contains('has not been asked'));
      expect(bridge.latest.summary, isNot(contains('empty')));
    });
  });

  group('host → device', () {
    test('sends SET_CLIPBOARD and reports the acknowledgement', () async {
      host.text = 'from Windows';
      final bridge = build(timeout: const Duration(seconds: 5));
      final pending = bridge.copyHostToDevice();
      await Future<void>.delayed(Duration.zero);
      expect(channel.sent, hasLength(1));
      expect(channel.sent.single.first, 9, reason: 'TYPE_SET_CLIPBOARD');
      final sequence = ByteData.sublistView(channel.sent.single).getInt64(1);
      channel.deliverAck(sequence);
      final write = await pending;
      expect(write.isAcknowledged, isTrue);
    });

    test('never sends sequence 0, which the server would not acknowledge', () async {
      // ControlMessage.SEQUENCE_INVALID is 0 and means "do not acknowledge",
      // so a write numbered zero could never be confirmed at all.
      host.text = 'x';
      final bridge = build();
      await bridge.copyHostToDevice();
      expect(ByteData.sublistView(channel.sent.single).getInt64(1), isNonZero);
    });

    test('a write nobody acknowledged is neither a success nor a failure', () async {
      host.text = 'sent into the void';
      final bridge = build();
      final write = await bridge.copyHostToDevice();
      expect(write.outcome, DeviceClipboardWriteOutcome.unacknowledged);
      expect(write.detail, contains('may or may not'));
      // And it does not claim to have copied anything.
      expect(write.isAcknowledged, isFalse);
    });

    test('an ack for a stale sequence does not answer the live write', () async {
      host.text = 'current';
      final bridge = build();
      final pending = bridge.copyHostToDevice();
      await Future<void>.delayed(Duration.zero);
      channel.deliverAck(9999);
      final write = await pending;
      expect(write.outcome, DeviceClipboardWriteOutcome.unacknowledged);
    });

    test('a host clipboard that would not open is refused, not sent', () async {
      host.readFailure = 'Something else is holding it.';
      final bridge = build();
      final write = await bridge.copyHostToDevice();
      expect(write.outcome, DeviceClipboardWriteOutcome.refused);
      expect(write.detail, 'Something else is holding it.');
      expect(channel.sent, isEmpty);
    });

    test('an empty host clipboard is refused with its own reason', () async {
      final bridge = build();
      final write = await bridge.copyHostToDevice();
      expect(write.outcome, DeviceClipboardWriteOutcome.refused);
      expect(write.detail, contains('no text on this computer'));
      expect(channel.sent, isEmpty);
    });

    test('a closed socket refuses in words rather than doing nothing', () async {
      host.text = 'anything';
      channel.close();
      final bridge = build();
      final write = await bridge.copyHostToDevice();
      expect(write.outcome, DeviceClipboardWriteOutcome.refused);
      expect(write.detail, contains('control socket'));
      expect(channel.sent, isEmpty);
    });

    test('a socket that refuses the write says so', () async {
      channel.accepts = false;
      final bridge = build();
      final write = await bridge.writeToDevice('text');
      expect(write.outcome, DeviceClipboardWriteOutcome.refused);
    });
  });

  group('device → host', () {
    test('asks with GET_CLIPBOARD and copies the answer to this computer', () async {
      final bridge = build(timeout: const Duration(seconds: 5));
      final pending = bridge.copyDeviceToHost();
      await Future<void>.delayed(Duration.zero);
      expect(channel.sent.single, [8, 0], reason: 'TYPE_GET_CLIPBOARD, no copy key');
      channel.deliverClipboard('copied on the phone');
      final read = await pending;
      expect(read.hasText, isTrue);
      expect(read.text, 'copied on the phone');
      expect(read.source, DeviceClipboardSource.requested);
      expect(host.text, 'copied on the phone');
    });

    test('a device that answers with nothing is empty — and says so', () async {
      final bridge = build(timeout: const Duration(seconds: 5));
      final pending = bridge.readFromDevice();
      await Future<void>.delayed(Duration.zero);
      channel.deliverClipboard('');
      final read = await pending;
      expect(read.outcome, DeviceClipboardOutcome.empty);
      expect(read.wasObserved, isTrue);
      expect(read.summary, contains('empty'));
    });

    test('a device that does not answer is UNAVAILABLE, never empty', () async {
      // The whole feature's honesty is this assertion.
      final bridge = build();
      final read = await bridge.readFromDevice();
      expect(read.outcome, DeviceClipboardOutcome.unavailable);
      expect(read.outcome, isNot(DeviceClipboardOutcome.empty));
      expect(read.wasObserved, isFalse);
      expect(read.text, isNull);
      expect(read.reason, contains('is not empty'));
      expect(read.reason, contains('READ_CLIPBOARD_IN_BACKGROUND'));
    });

    test('a device that could not be read does not clear the host clipboard', () async {
      host.text = 'something the user copied here';
      final bridge = build();
      final read = await bridge.copyDeviceToHost();
      expect(read.wasObserved, isFalse);
      expect(host.text, 'something the user copied here');
    });

    test('trailing whitespace survives — it is part of what was copied', () async {
      final bridge = build(timeout: const Duration(seconds: 5));
      final pending = bridge.readFromDevice();
      await Future<void>.delayed(Duration.zero);
      channel.deliverClipboard('  padded \n');
      expect((await pending).text, '  padded \n');
    });
  });

  group('the push, which is an event and not a poll', () {
    test('an unprompted clipboard becomes the latest reading, with a source', () async {
      final bridge = build();
      channel.deliverClipboard('copied on the phone');
      await Future<void>.delayed(Duration.zero);
      expect(bridge.latest.hasText, isTrue);
      expect(bridge.latest.source, DeviceClipboardSource.pushedByDevice);
      // Not written to this computer's clipboard: that takes an explicit act.
      expect(host.text, isNull);
    });

    test('it announces the change without carrying the text', () async {
      final bridge = build();
      final seen = <void>[];
      bridge.changes.listen(seen.add);
      channel.deliverClipboard('one');
      await Future<void>.delayed(Duration.zero);
      channel.deliverClipboard('two');
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
    });

    test('the pushed value can be taken without a round trip', () async {
      final bridge = build();
      channel.deliverClipboard('already known');
      await Future<void>.delayed(Duration.zero);
      final before = channel.sent.length;
      final read = await bridge.copyLatestToHost();
      expect(read.hasText, isTrue);
      expect(host.text, 'already known');
      expect(channel.sent.length, before, reason: 'nothing was asked');
    });

    test('with nothing pushed, taking the latest is not "empty"', () async {
      final bridge = build();
      final read = await bridge.copyLatestToHost();
      expect(read.outcome, DeviceClipboardOutcome.unavailable);
      expect(host.text, isNull);
    });
  });

  group('a socket this build can no longer read', () {
    test('an unknown device message stops the bridge and explains itself', () async {
      final bridge = build();
      channel.deliver([7, 1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.isOpen, isFalse);
      expect(bridge.refusal, contains('cannot read'));
      final read = await bridge.readFromDevice();
      expect(read.outcome, DeviceClipboardOutcome.unavailable);
    });
  });

  group('what it costs', () {
    test('a read and a write spawn no processes at all', () async {
      // The socket is already open, so neither direction is a subprocess —
      // which is also why nothing here can spawn on the drawing isolate.
      final before = processSpawnsOnThisIsolate;
      host.text = 'text';
      final bridge = build();
      await bridge.copyHostToDevice();
      await bridge.readFromDevice();
      await bridge.copyLatestToHost();
      expect(processSpawnsOnThisIsolate, before);
    });
  });
}
