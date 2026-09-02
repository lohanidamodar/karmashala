// A device that answers the way `adb forward` does, for tests that need the
// real socket handling rather than a mock of it.
//
// The video arrives over a genuine loopback `ServerSocket` in scrcpy's wire
// format, so the parser, the socket lifecycle and the watchdog are all live
// code; only adb and the server process are faked. It also keeps the device's
// side of the story — which servers it believes are running — so a test can ask
// what was left behind rather than only what the app asked for.
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/data/adb_service.dart';
import 'package:karmashala/src/features/devices/data/device_stream.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';

import '../../support/fake_command_runner.dart';

const AndroidSdk kFakeSdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

/// scrcpy's framing: `u64 pts-and-flags`, `u32 size`, then the payload.
Uint8List scrcpyPacket(
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
Uint8List scrcpyOpeningBytes() => Uint8List.fromList([
  ...'h264'.codeUnits,
  ...scrcpyPacket(8, config: true),
  ...scrcpyPacket(16, ptsUs: 1000, key: true),
]);

final RegExp _scidPattern = RegExp(r'sci\[?d\]?=([0-9a-f]+)');

class FakeScrcpyDevice {
  FakeScrcpyDevice._(this._server) {
    _server.listen((socket) {
      _sockets.add(socket);
      socket.listen(
        (_) {},
        onDone: () => _closedByHost += 1,
        onError: (Object _) => _closedByHost += 1,
      );
      // Each session opens video first and control second, so every odd
      // arrival is a video socket — and a restart's new session must be fed
      // too, or it never sees the bytes that prove the stream is up.
      if (_sockets.length.isOdd) {
        _videoSockets.add(socket);
        socket.add(scrcpyOpeningBytes());
      }
    });
  }

  static Future<FakeScrcpyDevice> bind() async =>
      FakeScrcpyDevice._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final List<Socket> _sockets = [];
  final List<Socket> _videoSockets = [];
  int _closedByHost = 0;

  /// Every scrcpy server process the app asked this device to start.
  final List<FakeProcessHandle> handles = [];

  /// The scids of servers the device believes are still running: started and
  /// not yet `pkill`ed. This is the leak, stated from the device's side.
  final Set<String> runningScids = {};

  /// Jar paths pushed and not yet unlinked or removed.
  final Set<String> pushedJars = {};

  int get port => _server.port;

  /// Sockets the app opened, and how many of them it has since let go.
  int get socketsAccepted => _sockets.length;
  int get socketsClosedByHost => _closedByHost;

  /// The video socket of the newest session.
  Socket get video => _videoSockets.last;

  /// One more frame, so a stream is demonstrably live before it goes quiet.
  void sendFrame(int ptsUs) =>
      video.add(scrcpyPacket(16, ptsUs: ptsUs, key: true));

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

  /// [processList] overrides what `adb shell ps` answers. Left alone, the
  /// device answers honestly: the servers it has been asked to start and not
  /// yet asked to kill.
  FakeCommandRunner runner({String? processList}) => FakeCommandRunner(
    responder: (request) {
      final arguments = request.arguments;
      if (arguments.contains('push')) {
        pushedJars.add(arguments.last);
      }
      if (arguments.contains('rm')) {
        pushedJars.remove(arguments.last);
      }
      if (arguments.contains('pkill')) {
        final scid = _scidPattern.firstMatch(arguments.last)?.group(1);
        if (scid != null) {
          runningScids.remove(scid);
          pushedJars.remove(scrcpyJarPathFor(scid));
        }
      }
      if (arguments.contains('tcp:0')) {
        return CommandResult(exitCode: 0, stdout: '$port\n', stderr: '');
      }
      if (arguments.contains('ps')) {
        return CommandResult(
          exitCode: 0,
          stdout: processList ?? _processTable(),
          stderr: '',
        );
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    },
    processFactory: (request) {
      final scid = _scidPattern
          .firstMatch(request.arguments.join(' '))
          ?.group(1);
      if (scid != null) runningScids.add(scid);
      final handle = FakeProcessHandle();
      handles.add(handle);
      return handle;
    },
  );

  String _processTable() => [
    for (final scid in runningScids)
      ' 6797 sh -c CLASSPATH=${scrcpyJarPathFor(scid)} app_process / '
          'com.genymobile.scrcpy.Server 4.1 scid=$scid',
    '',
  ].join('\n');
}

DeviceStreamService fakeStreamService(
  FakeCommandRunner runner, {
  Duration stallTimeout = const Duration(milliseconds: 300),
  Duration watchdogInterval = const Duration(milliseconds: 25),
  Duration livenessProbeInterval = const Duration(seconds: 30),
  Duration inputAnswerGrace = const Duration(milliseconds: 200),
}) => DeviceStreamService(
  adb: AdbService(runner: runner, sdk: kFakeSdk),
  runner: runner,
  serverBytes: () async => Uint8List(4),
  stallTimeout: stallTimeout,
  watchdogInterval: watchdogInterval,
  livenessProbeInterval: livenessProbeInterval,
  inputAnswerGrace: inputAnswerGrace,
  socketAttempts: 10,
);
