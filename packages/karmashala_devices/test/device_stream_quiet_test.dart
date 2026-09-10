// **What a live view does while a host file dialog is being built.** Every byte
// of this stream is handled on the Dart isolate, which on Windows is the thread
// `IFileOpenDialog` is created on. Two things must hold: it must really stop
// taking bytes, and stopping must cost the session nothing — no closed socket,
// no restart, and no watchdog verdict about a silence this app asked for.
import 'dart:async';

import 'package:karmashala_devices/src/data/device_stream.dart';
import 'package:test/test.dart';

import './fake_scrcpy_device.dart';

const _serial = 'F6IZLV6LMFT4U4ZT';

/// Polls until [reached], or gives up. The stream is fed by events on the far
/// side of a real socket, so "already there" is never safe to assume.
Future<void> _until(
  bool Function() reached, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final waited = Stopwatch()..start();
  while (!reached()) {
    if (waited.elapsed > limit) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('a quiet session takes nothing off the socket, and keeps it', () async {
    final device = await FakeScrcpyDevice.bind();
    addTearDown(device.dispose);
    final session = await fakeStreamService(device.runner()).start(_serial);
    addTearDown(session.stop);

    // Live before it goes quiet, or the assertion below proves nothing.
    await _until(() => session.mark.frames > 0);
    final before = session.mark.frames;
    final socketsOpen = device.socketsAccepted;

    session.setQuiet(true);
    for (var i = 0; i < 5; i++) {
      device.sendFrame(2000 + i * 1000);
    }
    // Long enough that a subscription still taking bytes would have taken them.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      session.mark.frames,
      before,
      reason: 'a quiet stream parses nothing, so the isolate does nothing',
    );
    // The whole point of pausing rather than stopping: the device is still
    // connected and still encoding, so there is nothing to reconnect.
    expect(device.socketsClosedByHost, 0);
    expect(device.socketsAccepted, socketsOpen);

    session.setQuiet(false);

    // The five frames were held by TCP, not thrown away.
    await _until(() => session.mark.frames > before);
    expect(session.mark.frames, greaterThan(before));
  });

  test('the silence a picker asked for is not a verdict about the stream', () async {
    final device = await FakeScrcpyDevice.bind();
    addTearDown(device.dispose);
    // `stallTimeout` is 300 ms here and the watchdog ticks every 25 ms, so the
    // window below is four stall timeouts wide.
    final session = await fakeStreamService(device.runner()).start(_serial);
    addTearDown(session.stop);

    final reports = <DeviceStreamHealth>[];
    final health = session.health.listen(reports.add);
    addTearDown(health.cancel);

    await _until(() => session.mark.frames > 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    reports.clear();

    session.setQuiet(true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    session.setQuiet(false);
    device.sendFrame(9000);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Not merely "never stalled": nothing at all. An `idle` verdict is healthy
    // and would still put "No screen changes for 1s" under the picture.
    expect(
      reports,
      isEmpty,
      reason: 'the watchdog judged a gap this app asked for: $reports',
    );
  });

  test('quiet is idempotent, and a stopped session ignores it', () async {
    final device = await FakeScrcpyDevice.bind();
    addTearDown(device.dispose);
    final session = await fakeStreamService(device.runner()).start(_serial);

    await _until(() => session.mark.frames > 0);
    session
      ..setQuiet(true)
      ..setQuiet(true)
      ..setQuiet(false)
      ..setQuiet(false);
    await _until(() => session.mark.frames > 0);

    await session.stop();
    // The registry lets go of its hook after the session has gone. Pausing a
    // cancelled subscription throws; this must not.
    expect(() => session.setQuiet(true), returnsNormally);
    expect(() => session.setQuiet(false), returnsNormally);
  });
}
