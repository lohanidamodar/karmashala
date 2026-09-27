import 'dart:async';
import 'dart:io';

import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import 'device_ports.dart';
import 'ios_device_providers.dart';

final mp4WriterOpenerProvider = Provider<Mp4WriterOpener>(
  (ref) => Mp4RecordingWriter.open,
);

/// The directory recordings go in, created if it is missing — `simctl` writes
/// its own file and would otherwise need a second way to make the folder.
final deviceRecordingDirectoryProvider = Provider<Future<String> Function()>(
  (ref) => () async {
    final directory = Directory(
      p.join(
        (await ref.read(deviceDataDirectoryProvider)()).path,
        kDeviceRecordingsFolder,
      ),
    );
    await directory.create(recursive: true);
    return directory.path;
  },
);

final recordingSinkOpenerProvider = Provider<RecordingSinkOpener>(
  (ref) => FileRecordingSink.open,
);

final deviceRecordingProvider =
    NotifierProvider<DeviceRecordingController, DeviceRecordingState>(
      DeviceRecordingController.new,
    );

/// The pane's one [DeviceRecorder], held in a provider, since a pane switch
/// would strand it. The recording is the live view's — this machine's.
class DeviceRecordingController extends Notifier<DeviceRecordingState> {
  late DeviceRecorder _recorder;

  @override
  DeviceRecordingState build() {
    final recorder = _recorder = DeviceRecorder(
      clock: ref.read(deviceClockProvider),
      recordingDirectory: ref.read(deviceRecordingDirectoryProvider),
      simctl: () => ref.read(simctlServiceProvider),
      openMp4: ref.read(mp4WriterOpenerProvider),
      openSink: ref.read(recordingSinkOpenerProvider),
    );
    recorder.onChanged = (next) => state = next;
    // The app is closing: close the file, and write no outcome nobody reads.
    ref.onDispose(() {
      recorder.onChanged = null;
      unawaited(recorder.abandon());
    });
    return recorder.state;
  }

  /// See [DeviceRecorder.offerLiveView].
  void offerLiveView(LiveViewRecordingSource source) =>
      _recorder.offerLiveView(source);

  /// See [DeviceRecorder.startLiveViewRecording].
  Future<void> startLiveViewRecording({
    DeviceRecordingContainer container =
        DeviceRecordingContainer.transportStream,
  }) => _recorder.startLiveViewRecording(container: container);

  /// See [DeviceRecorder.startSimulatorRecording].
  Future<void> startSimulatorRecording(SimulatorTarget target) =>
      _recorder.startSimulatorRecording(target);

  /// Ends the recording and writes its outcome. Idempotent.
  Future<void> stop() => _recorder.stop();

  /// Clears the last outcome once the user has read it.
  void dismiss() => _recorder.dismiss();
}
