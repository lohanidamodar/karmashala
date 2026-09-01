import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/data/adb_service.dart';
import 'package:karmashala/src/features/devices/data/device_gesture_sink.dart';
import 'package:karmashala/src/features/devices/data/scrcpy_control.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/device_input.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

const _video = DeviceScreenSize(width: 472, height: 1024);
const _screen = DeviceScreenSize(width: 1080, height: 2340);

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

/// A real loopback socket pair, so the connection under test is the shipped
/// class rather than a stand-in — including how it behaves when the far end
/// disappears, which is the case the fallback depends on.
class _Wire {
  _Wire(this.server, this.client, this.received);

  final ServerSocket server;
  final Socket client;
  final List<int> received;

  static Future<_Wire> open() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = <int>[];
    final accepted = server.first;
    final client = await Socket.connect('127.0.0.1', server.port);
    (await accepted).listen(received.addAll);
    return _Wire(server, client, received);
  }

  Future<void> close() async {
    client.destroy();
    await server.close();
  }

  /// The touch messages seen so far, decoded back off the wire.
  List<({int action, int pointer, int x, int y, int w, int h, int pressure})>
  get touches {
    final bytes = Uint8List.fromList(received);
    final view = ByteData.sublistView(bytes);
    final out =
        <
          ({int action, int pointer, int x, int y, int w, int h, int pressure})
        >[];
    for (var i = 0; i + 32 <= bytes.length; i += 32) {
      out.add((
        action: view.getUint8(i + 1),
        pointer: view.getUint64(i + 2),
        x: view.getInt32(i + 10),
        y: view.getInt32(i + 14),
        w: view.getUint16(i + 18),
        h: view.getUint16(i + 20),
        pressure: view.getUint16(i + 22),
      ));
    }
    return out;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  group('ScrcpyGestureSink', () {
    late _Wire wire;
    late ScrcpyControlConnection connection;

    setUp(() async {
      wire = await _Wire.open();
      connection = ScrcpyControlConnection(wire.client);
    });

    tearDown(() async {
      await connection.close();
      await wire.close();
    });

    ScrcpyGestureSink sinkOver(
      DeviceScreenSize? Function() size, {
      void Function()? onDropped,
    }) => ScrcpyGestureSink(
      connection: connection,
      videoSize: size,
      onDropped: onDropped,
    );

    test('a drag becomes down, every move, then up', () async {
      final sink = sinkOver(() => _video);
      sink.pointerDown(0, 0.5, 0.5);
      for (var i = 1; i <= 4; i++) {
        sink.pointerMove(0, 0.5, 0.5 - 0.1 * i);
      }
      sink.pointerUp(0, 0.5, 0.1, const Duration(milliseconds: 400));
      await settle();

      expect(wire.touches.map((t) => t.action), [
        AndroidMotionAction.down,
        AndroidMotionAction.move,
        AndroidMotionAction.move,
        AndroidMotionAction.move,
        AndroidMotionAction.move,
        AndroidMotionAction.up,
      ]);
    });

    test('positions are scaled into the video space, not the screen', () async {
      // The distinction is load-bearing: `PositionMapper.map` compares the
      // declared size against scrcpy's video size and silently drops the event
      // when they differ, so sending device pixels does nothing at all.
      sinkOver(() => _video).pointerDown(0, 0.5, 0.25);
      await settle();
      final touch = wire.touches.single;
      expect(touch.w, 472);
      expect(touch.h, 1024);
      expect(touch.x, 236);
      expect(touch.y, 256);
    });

    test('a rotation mid-gesture is picked up on the next event', () async {
      var size = _video;
      final sink = sinkOver(() => size);
      sink.pointerDown(0, 0.5, 0.5);
      size = const DeviceScreenSize(width: 1024, height: 472);
      sink.pointerMove(0, 0.5, 0.5);
      await settle();
      expect(wire.touches[0].w, 472);
      expect(wire.touches[1].w, 1024);
    });

    test('pressure is full while down and zero on release', () async {
      final sink = sinkOver(() => _video);
      sink.pointerDown(0, 0.5, 0.5);
      sink.pointerUp(0, 0.5, 0.5, Duration.zero);
      await settle();
      expect(wire.touches[0].pressure, 0xFFFF);
      expect(wire.touches[1].pressure, 0);
    });

    test('two fingers keep their own pointer ids', () async {
      final sink = sinkOver(() => _video);
      sink.pointerDown(0, 0.2, 0.2);
      sink.pointerDown(1, 0.8, 0.8);
      sink.pointerMove(1, 0.7, 0.7);
      sink.pointerUp(0, 0.3, 0.3, Duration.zero);
      await settle();
      expect(wire.touches.map((t) => t.pointer), [0, 1, 1, 0]);
    });

    test('a move for a finger that never went down is not sent', () async {
      // Otherwise a gesture that began before the socket existed would send
      // orphan moves, and scrcpy would log "too many pointers" on the next one.
      sinkOver(() => _video).pointerMove(4, 0.5, 0.5);
      await settle();
      expect(wire.touches, isEmpty);
    });

    test('nothing is sent before the video size is known', () async {
      sinkOver(() => null).pointerDown(0, 0.5, 0.5);
      await settle();
      expect(wire.touches, isEmpty);
    });

    test('a closed socket reports the drop instead of swallowing it', () async {
      var dropped = false;
      final sink = sinkOver(() => _video, onDropped: () => dropped = true);
      await connection.close();
      sink.pointerDown(0, 0.5, 0.5);
      expect(dropped, isTrue, reason: 'the pane needs to fall back');
      expect(connection.isOpen, isFalse);
    });

    test('names itself as the continuous transport', () {
      expect(
        sinkOver(() => _video).transport,
        DeviceGestureTransport.scrcpyControl,
      );
      expect(DeviceGestureTransport.scrcpyControl.isContinuous, isTrue);
    });
  });

  group('AdbGestureSink', () {
    late FakeCommandRunner runner;
    late AdbGestureSink sink;

    setUp(() {
      runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      sink = AdbGestureSink(
        adb: AdbService(runner: runner, sdk: _sdk()),
        serial: 'emulator-5554',
        screen: _screen,
      );
    });

    List<String> argv() => runner.requests.single.arguments;

    test('a press that goes nowhere is a tap', () async {
      sink.pointerDown(0, 0.5, 0.5);
      sink.pointerUp(0, 0.5, 0.5, const Duration(milliseconds: 80));
      await settle();
      expect(argv(), [
        '-s',
        'emulator-5554',
        'shell',
        'input',
        'tap',
        '540',
        '1170',
      ]);
    });

    test('a press held still is a long press, not a tap', () async {
      sink.pointerDown(0, 0.5, 0.5);
      sink.pointerUp(0, 0.5, 0.5, const Duration(milliseconds: 900));
      await settle();
      expect(argv().sublist(4), [
        'swipe',
        '540',
        '1170',
        '540',
        '1170',
        // Same reason as the swipe floor below: 700 ms is the argument adb
        // receives, and it has to clear Android's own 500 ms threshold.
        '700',
      ]);
    });

    test('a drag becomes one swipe, on release', () async {
      sink.pointerDown(0, 0.5, 0.8);
      sink.pointerMove(0, 0.5, 0.6);
      sink.pointerMove(0, 0.5, 0.4);
      // Nothing has been sent yet, and that is the ceiling this fallback has.
      expect(runner.requests, isEmpty);
      sink.pointerUp(0, 0.5, 0.4, const Duration(milliseconds: 500));
      await settle();
      expect(argv().sublist(4), ['swipe', '540', '1872', '540', '936', '500']);
    });

    test('the duration carries the velocity through', () async {
      sink.pointerDown(0, 0.5, 0.8);
      sink.pointerUp(0, 0.5, 0.2, const Duration(milliseconds: 5));
      await settle();
      // Floored: below this Android reads an implausible velocity. The literal
      // is the point — it is the argument `input swipe` is actually given, and
      // asserting it against `kMinSwipeDuration` would survive a change to it.
      expect(argv().last, '60');
    });

    test(
      'a second finger is ignored rather than mixed into the first',
      () async {
        sink.pointerDown(0, 0.2, 0.2);
        sink.pointerDown(1, 0.8, 0.8);
        sink.pointerUp(1, 0.8, 0.8, const Duration(milliseconds: 50));
        await settle();
        expect(runner.requests, isEmpty, reason: 'input has no multi-touch');
        sink.pointerUp(0, 0.2, 0.2, const Duration(milliseconds: 50));
        await settle();
        expect(argv().sublist(4), ['tap', '216', '468']);
      },
    );

    test('a cancelled gesture sends nothing', () async {
      sink.pointerDown(0, 0.5, 0.5);
      sink.pointerCancel(0);
      sink.pointerUp(0, 0.5, 0.2, const Duration(milliseconds: 300));
      await settle();
      expect(runner.requests, isEmpty);
    });

    test('names itself as the non-continuous transport', () {
      expect(sink.transport, DeviceGestureTransport.adbInput);
      expect(DeviceGestureTransport.adbInput.isContinuous, isFalse);
    });
  });
}
