// What the watchdog is allowed to call a fault.
//
// The bug these cover was reproduced on F6IZLV6LMFT4U4ZT from the app's own
// log: 28 restarts in nine minutes, every 11 seconds, with the phone awake and
// sitting on a static screen — and **no** `stream ended` or `scrcpy-server
// exited` line among them. The restarts were the watchdog calling frame
// silence a stall, and scrcpy sends no frames at all once the picture stops
// changing (it asks the encoder for `repeat-previous-frame-after`, which the
// platform honours only for a bounded burst).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/data/device_stream.dart';

import 'fake_scrcpy_device.dart';

void main() {
  group('the watchdog', () {
    test('a screen that stops changing is idle, not a fault', () async {
      // The reproduction. scrcpy encodes on change: a phone left on a home
      // screen sends nothing at all, and calling that a stall is what restarted
      // the owner's live view every eleven seconds for nine minutes.
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
      // The 1.6.0 report, in one case: "the live view goes stale after some
      // time and doesn't update when i interact". Silence with nobody asking is
      // idleness; silence while the user is asking is a live view that has
      // stopped working, and the two are the same picture on screen.
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
      // The failure 1.6.0 had no signal for at all. Everything the old rule
      // watched is perfect here — server alive, socket open, frames decoding —
      // and the picture on screen has not moved since the player stopped
      // consuming. It reported `live` throughout, so nothing was on screen to
      // say the picture was old: a stale frame that looks live is the one thing
      // this pane must never show.
      final device = await FakeScrcpyDevice.bind();
      addTearDown(device.dispose);
      final session = await fakeStreamService(
        device.runner(),
      ).start('F6IZLV6LMFT4U4ZT');
      addTearDown(session.stop);

      final seen = <DeviceStreamHealth>[];
      session.health.listen(seen.add);

      // A viewer that connects, takes the head, and then stops reading — the
      // player equivalent of a frozen decoder. Nothing is closed: this is
      // backpressure, not a disconnection.
      final viewer = await Socket.connect(session.url.host, session.url.port);
      addTearDown(() async => viewer.destroy());
      final reading = viewer.listen((_) {});
      viewer.write(
        'GET ${session.url.path} HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n\r\n',
      );
      await viewer.flush();
      // The first bytes a viewer sees are the HTTP head, which the response
      // writes itself; the delivery clock only starts when one of *our* chunks
      // has flushed.
      for (var i = 0; i < 100 && session.mark.writtenUs == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.mark.writtenUs, greaterThan(0));
      reading.pause();

      // Keep the device sending. Bounded by frames, not by a clock: the write
      // chain stalls once the socket buffers fill, and a megabyte or two is
      // past any platform's default.
      // The *entry that reported the stall*, not whichever arrived last: the
      // loop stops on the first matching report, but the watchdog keeps
      // ticking, so a later health entry can land between the loop exiting
      // and these assertions. Reading `seen.last` made this test fail under
      // machine load with `live` in hand, having genuinely seen the stall.
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
      // The cheapest rung of the ladder, end to end: one byte down the control
      // socket the app already holds. The server answers it by restarting
      // video capture — a fresh config and keyframe — with the process, the
      // forward, both sockets and the player left exactly as they are.
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
      // Loop 36's failure, and the one case where silence really is death: the
      // server was gone while its `adb forward` entry — and the host-side
      // socket — stayed up. The probe is what turns "no frames" into "no
      // server", and only a process table that actually answered counts.
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
      // A probe that treated an empty process table as "the server is gone"
      // would restart the stream every time adb hiccupped — the same bug in a
      // new place.
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
