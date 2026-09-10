// What the watchdog is allowed to call a fault. Reproduced from the app's own
// log: 28 restarts in nine minutes, every 11 seconds, on a static screen with
// no `stream ended` line among them — scrcpy sends no frames at all once the
// picture stops changing.
import 'dart:io';

import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/device_stream.dart';

import './fake_scrcpy_device.dart';

void main() {
  group('the watchdog', () {
    test('a screen that stops changing is idle, not a fault', () async {
      // The reproduction: a phone left on a home screen sends nothing at all,
      // and calling that a stall is what restarted the view every 11 seconds.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(device.runner()).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);
      device.sendFrame(2000);
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(
        seen.map((h) => h.state),
        contains(DeviceStreamState.idle),
        reason: 'silence on a live connection is idle',
      );
      expect(
        seen.map((h) => h.state),
        isNot(contains(DeviceStreamState.stalled)),
        reason: 'nothing is wrong: the connection is up and the server is alive',
      );
      expect(
        seen.map((h) => h.state),
        isNot(contains(DeviceStreamState.ended)),
      );
      expect(
        seen.last.detail,
        contains('No screen changes'),
        reason: 'worth saying, not worth restarting for',
      );
      expect(seen.last.isHealthy, isTrue);
    });

    test('frames arriving again ends the idle report', () async {
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(device.runner()).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(seen.map((h) => h.state), contains(DeviceStreamState.idle));

      device.sendFrame(3000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen.last.state, DeviceStreamState.live);
    });

    test('a device that will not answer the user is a fault, not idleness',
        () async {
      // Silence with nobody asking is idleness; silence while the user is
      // asking is a live view that has stopped working, and both look the same.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);
      // Three interactions, far enough apart to be three rather than one.
      for (var i = 0; i < 3; i++) {
        session.noteInput();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(seen.last.state, DeviceStreamState.stalled);
      expect(seen.last.detail, contains('has not answered'));
      expect(seen.last.needsRestart, isTrue);
    });

    test('a drag is one unanswered request, not fifty', () async {
      // Pointer moves arrive every few milliseconds. Counting events rather
      // than interactions would condemn a healthy stream inside one swipe.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);
      for (var i = 0; i < 50; i++) {
        session.noteInput();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(session.mark.unansweredInputs, 1);
      expect(
        seen.map((h) => h.state),
        isNot(contains(DeviceStreamState.stalled)),
      );
    });

    test('a frame answers everything the user asked for', () async {
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      for (var i = 0; i < 3; i++) {
        session.noteInput();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(session.mark.unansweredInputs, 3);
      device.sendFrame(5000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(session.mark.unansweredInputs, 0);
    });

    test('frames the player has stopped taking are a fault', () async {
      // Everything the old rule watched is perfect here — server alive, socket
      // open, frames decoding — and the picture has not moved since the player
      // stopped consuming. A stale frame that looks live is the worst case.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);

      // A viewer that connects, takes the head and then stops reading. Nothing
      // is closed: this is backpressure, not a disconnection.
      final viewer = await Socket.connect(session.url.host, session.url.port);
      addTearDown(() async => viewer.destroy());
      final reading = viewer.listen((_) {});
      viewer.write(
        'GET ${session.url.path} HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n\r\n',
      );
      await viewer.flush();
      // The first bytes a viewer sees are the HTTP head; the delivery clock
      // only starts when one of *our* chunks has flushed.
      for (var i = 0; i < 100 && session.mark.writtenUs == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.mark.writtenUs, greaterThan(0));
      reading.pause();

      // Bounded by frames, not by a clock: the write chain stalls once the
      // socket buffers fill. And the *entry that reported the stall*, not
      // whichever arrived last — the watchdog keeps ticking after the loop.
      DeviceStreamHealth? stall;
      for (var i = 0; i < 64 && stall == null; i++) {
        device.video.add(scrcpyPacket(131072, ptsUs: 10000 + i, key: true));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        stall = seen
            .where((h) => h.detail.contains('picture has not updated'))
            .firstOrNull;
      }

      expect(
        stall,
        isNotNull,
        reason: 'the delivery clock never noticed a viewer that stopped '
            'reading; states seen: ${seen.map((h) => h.state).toSet()}',
      );
      expect(stall!.state, DeviceStreamState.stalled);
      expect(stall.needsRestart, isTrue);
    });

    test('a frozen picture can be repaired without tearing anything down',
        () async {
      // The cheapest rung end to end: one byte down the control socket, with
      // the process, the forward, both sockets and the player left as they are.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final runner = device.runner();
      final session = await fakeStreamService(runner).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      expect(session.requestVideoReset(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        device.controlBytes,
        [17],
        reason: 'TYPE_RESET_VIDEO, and nothing after it: the server reads one '
            'byte, so a payload would be read as the next message type',
      );
      // Nothing was torn down to do it.
      expect(device.runningScids, hasLength(1));
      expect(device.socketsClosedByHost, 0);
      expect(runner.startRequests, hasLength(1));
    });

    test('a session with no control socket says the rung is unavailable',
        () async {
      // Not an error: `adb shell input` still drives the device. But the cheap
      // recovery is gone, which is what the caller needs to know.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(),
      ).start('F6IZLV6LMFT4U4ZT', useControlSocket: false);
      addTearDown(session.stop);

      expect(session.control, isNull);
      expect(session.requestVideoReset(), isFalse);
      expect(device.controlBytes, isEmpty);
    });

    test('a closed socket is ended, and that is a fault', () async {
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(device.runner()).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final ended = session.health.firstWhere(
        (h) => h.state == DeviceStreamState.ended,
      );
      await device.closeVideo();
      final health = await ended.timeout(const Duration(seconds: 2));
      expect(health.needsRestart, isTrue);
      expect(health.isHealthy, isFalse);
    });

    test('the server exiting is ended, and that is a fault', () async {
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(device.runner()).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final ended = session.health.firstWhere(
        (h) => h.state == DeviceStreamState.ended,
      );
      device.handles.last.complete(1);
      final health = await ended.timeout(const Duration(seconds: 2));
      expect(health.detail, contains('exited'));
      expect(health.needsRestart, isTrue);
    });

    test('silence outlives the server: the device-side process is checked',
        () async {
      // The one case where silence really is death: the server was gone while
      // its `adb forward` entry and the host-side socket stayed up.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(processList: 'USER PID ARGS\n 1 /init\n'),
        livenessProbeInterval: const Duration(milliseconds: 400),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final ended = await session.health
          .firstWhere((h) => h.state == DeviceStreamState.ended)
          .timeout(const Duration(seconds: 3));
      expect(ended.detail, contains('no longer running'));
      expect(ended.needsRestart, isTrue);
    });

    test('a server that is still there leaves the silence alone', () async {
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(),
        livenessProbeInterval: const Duration(milliseconds: 200),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(seen.map((h) => h.state), contains(DeviceStreamState.idle));
      expect(
        seen.map((h) => h.state),
        isNot(contains(DeviceStreamState.ended)),
        reason: 'the probe found the server; silence stays silence',
      );
      expect(seen.every((h) => h.isHealthy), isTrue);
    });

    test('an adb that cannot answer is not evidence of death', () async {
      // A probe that read an empty process table as "the server is gone" would
      // restart the stream every time adb hiccupped.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(processList: ''),
        livenessProbeInterval: const Duration(milliseconds: 200),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(
        seen.map((h) => h.state),
        isNot(contains(DeviceStreamState.ended)),
      );
    });
  });
}
