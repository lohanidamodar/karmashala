// What the watchdog is allowed to call a fault.
//
// The bug these cover was reproduced on F6IZLV6LMFT4U4ZT from the app's own
// log: 28 restarts in nine minutes, every 11 seconds, with the phone awake and
// sitting on a static screen — and **no** `stream ended` or `scrcpy-server
// exited` line among them. The restarts were the watchdog calling frame
// silence a stall, and scrcpy sends no frames at all once the picture stops
// changing (it asks the encoder for `repeat-previous-frame-after`, which the
// platform honours only for a bounded burst).
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
