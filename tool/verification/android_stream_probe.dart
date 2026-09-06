import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/local_command_runner.dart';
import 'package:karmashala/src/features/devices/data/adb_service.dart';
import 'package:karmashala/src/features/devices/data/device_stream.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/devices/presentation/device_pane.dart';
import 'package:media_kit/media_kit.dart';

// An opt-in probe, never part of the ordinary suite. Its own scrcpy session
// must not reap the live session the person is looking at.
class ProbeStream extends DeviceStreamService {
  ProbeStream({
    required super.adb,
    required super.runner,
    required super.serverBytes,
  });

  @override
  Future<int> reapOrphans(String serial) async => 0;
}

void main() {
  test('physical Android stream and native decoder progress', () async {
    const serial = String.fromEnvironment('DEVICE_SERIAL');
    const adbPath = String.fromEnvironment('ADB_PATH');
    const libmpv = String.fromEnvironment('LIBMPV_PATH');
    const samples = int.fromEnvironment('PROBE_SAMPLES', defaultValue: 45);
    if (serial.isEmpty || adbPath.isEmpty || libmpv.isEmpty) {
      fail('Pass DEVICE_SERIAL, ADB_PATH and LIBMPV_PATH with --dart-define.');
    }
    MediaKit.ensureInitialized(libmpv: libmpv);
    const runner = LocalCommandRunner();
    final adb = AdbService(
      runner: runner,
      sdk: AndroidSdk(
        root: EnvironmentPath(
          environmentId: 'windows', path: File(adbPath).parent.parent.path,
        ),
        adb: const EnvironmentPath(environmentId: 'windows', path: adbPath),
      ),
    );
    final service = ProbeStream(
      adb: adb,
      runner: runner,
      serverBytes: () => File('assets/scrcpy/scrcpy-server').readAsBytes(),
    );
    final session = await service.start(serial);
    addTearDown(session.stop);
    final health = session.health.listen((event) {
      // ignore: avoid_print
      print('HEALTH ${event.state}: ${event.detail}');
    });
    addTearDown(health.cancel);
    final player = Player(
      configuration: const PlayerConfiguration(
        vo: 'null', bufferSize: 256 * 1024,
        protocolWhitelist: ['file', 'tcp', 'http'],
      ),
    );
    addTearDown(player.dispose);
    final native = player.platform as NativePlayer;
    final errors = player.stream.error.listen((error) {
      // ignore: avoid_print
      print('PLAYER ERROR $error');
    });
    addTearDown(errors.cancel);
    await configureDeviceLivePlayer(native.setProperty);
    await native.setProperty('vid', 'auto');
    await player.open(Media(session.url.toString()));
    for (var sample = 0; sample < samples; sample++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final position = await native.getProperty('time-pos');
      final eof = await native.getProperty('eof-reached');
      final pause = await native.getProperty('pause');
      final networkTimeout = await native.getProperty('network-timeout');
      // ignore: avoid_print
      print('SAMPLE $sample received=${session.mark.frames} '
          'delivered=${session.mark.writtenUs} position=$position '
          'eof=$eof pause=$pause networkTimeout=$networkTimeout');
    }
    // State assertions, not latency thresholds. Read the sample sequence to
    // establish that input after idleness actually resumed decoding.
    expect(session.mark.frames, greaterThan(0));
    expect(await native.getProperty('eof-reached'), 'no');
    expect(await native.getProperty('pause'), 'no');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
