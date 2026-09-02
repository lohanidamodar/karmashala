// What the watchdog is allowed to call a fault.
//
// The bug these cover was reproduced on F6IZLV6LMFT4U4ZT from the app's own
// log: 28 restarts in nine minutes, every 11 seconds, with the phone awake and
// sitting on a static screen — and **no** `stream ended` or `scrcpy-server
// exited` line among them. The restarts were the watchdog calling frame
// silence a stall, and scrcpy sends no frames at all once the picture stops
// changing (it asks the encoder for `repeat-previous-frame-after`, which the
// platform honours only for a bounded burst).
//
// The device here is a real loopback `ServerSocket` speaking scrcpy's wire
// format, so the parser, the socket handling and the watchdog are the code
// under test; only adb and the server process are faked.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/data/adb_service.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/data/device_stream.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';

import '../../support/fake_command_runner.dart';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

/// scrcpy's framing: `u64 pts-and-flags`, `u32 size`, then the payload.
Uint8List _packet(
  int payloadLength, {
  int ptsUs = 0,
  bool config = false,
  bool key = false,
}) {
  final header = ByteData(12);
  var ptsAndFlags = ptsUs;
  if (config) ptsAndFlags |= 1 << 62;
  if (key) ptsAndFlags |= 1 << 61;
  header.setUint64(0, ptsAndFlags);
  header.setUint32(8, payloadLength);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...List.filled(payloadLength, 0xAB),
  ]);
}

/// The first bytes a real server sends: the codec id, SPS/PPS, one keyframe.
Uint8List _openingBytes() => Uint8List.fromList([
  ...'h264'.codeUnits,
  ..._packet(8, config: true),
  ..._packet(16, ptsUs: 1000, key: true),
]);

/// A device that answers on loopback the way `adb forward` does.
class _FakeDevice {
  _FakeDevice._(this._server, this.handles) {
    _server.listen((socket) {
      _sockets.add(socket);
      // The video socket is the first one connected; the control socket, when
      // there is one, is the second. Only the first ever carries video.
      if (_sockets.length == 1) socket.add(_openingBytes());
    });
  }

  static Future<_FakeDevice> bind() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeDevice._(server, <FakeProcessHandle>[]);
  }

  final ServerSocket _server;
  final List<Socket> _sockets = [];

  /// Every scrcpy server process this device was asked to start.
  final List<FakeProcessHandle> handles;

  int get port => _server.port;

  Socket get video => _sockets.first;

  /// One more frame, so the stream is demonstrably live before it goes quiet.
  void sendFrame(int ptsUs) => video.add(_packet(16, ptsUs: ptsUs, key: true));

  Future<void> closeVideo() async {
    await video.close();
    video.destroy();
  }

  Future<void> dispose() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }

  /// [processList] is what `adb shell ps` answers. `null` means "the server
  /// this session pushed is in the table", which is the ordinary case.
  FakeCommandRunner runner({String? processList}) {
    String? pushedJar;
    return FakeCommandRunner(
      responder: (request) {
        if (request.arguments.contains('push')) {
          pushedJar = request.arguments.last;
        }
        if (request.arguments.contains('tcp:0')) {
          return CommandResult(exitCode: 0, stdout: '$port\n', stderr: '');
        }
        if (request.arguments.contains('ps')) {
          final jar = pushedJar;
          return CommandResult(
            exitCode: 0,
            stdout:
                processList ??
                (jar == null
                    ? ''
                    : ' 6797 sh -c CLASSPATH=$jar app_process / '
                          'com.genymobile.scrcpy.Server 4.1\n'),
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
      processFactory: (_) {
        final handle = FakeProcessHandle();
        handles.add(handle);
        return handle;
      },
    );
  }
}

DeviceStreamService _service(
  FakeCommandRunner runner, {
  Duration stallTimeout = const Duration(milliseconds: 300),
  Duration livenessProbeInterval = const Duration(seconds: 30),
}) => DeviceStreamService(
  adb: AdbService(runner: runner, sdk: _sdk()),
  runner: runner,
  serverBytes: () async => Uint8List(4),
  stallTimeout: stallTimeout,
  watchdogInterval: const Duration(milliseconds: 25),
  livenessProbeInterval: livenessProbeInterval,
  socketAttempts: 10,
);

void main() {
  group('the watchdog', () {
    test('a screen that stops changing is idle, not a fault', () async {
      // The reproduction. scrcpy encodes on change: a phone left on a home
      // screen sends nothing at all, and calling that a stall is what restarted
      // the owner's live view every eleven seconds for nine minutes.
      final device = await _FakeDevice.bind();
      addTearDown(device.dispose);
      final session = await _service(device.runner()).start('F6IZLV6LMFT4U4ZT');
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
      final device = await _FakeDevice.bind();
      addTearDown(device.dispose);
      final session = await _service(device.runner()).start('F6IZLV6LMFT4U4ZT');
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
      final device = await _FakeDevice.bind();
      addTearDown(device.dispose);
      final session = await _service(device.runner()).start('F6IZLV6LMFT4U4ZT');
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
      final device = await _FakeDevice.bind();
      addTearDown(device.dispose);
      final session = await _service(device.runner()).start('F6IZLV6LMFT4U4ZT');
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
      final device = await _FakeDevice.bind();
      addTearDown(device.dispose);
      final session = await _service(
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
      final device = await _FakeDevice.bind();
      addTearDown(device.dispose);
      final session = await _service(
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
      final device = await _FakeDevice.bind();
      addTearDown(device.dispose);
      final session = await _service(
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
