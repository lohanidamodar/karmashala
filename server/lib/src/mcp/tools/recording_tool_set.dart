import 'dart:io';

import 'package:karmashala_core/util.dart' show SystemClock;
import 'package:karmashala_devices/karmashala_devices.dart';

import '../../devices/server_devices.dart';
import '../../domain/host_session.dart';
import '../../domain/session_registry.dart';
import '../../terminals/server_terminals.dart';
import 'recording_tool_schemas.dart';
import 'server_tool_set.dart';
import 'terminal_cast_recorder.dart';

/// **Recordings, made by the server** (slice 5b): a terminal's recording is an
/// asciicast written from the session's own bytes (a Karmashala window renders
/// it to video), and a device's is made on the server's own machine — an
/// Android device with its own `screenrecord`, a simulator with `simctl` —
/// through the pure [DeviceRecorder]. The device pane's live-view recording
/// stays a person's, in their window.
class RecordingToolSet extends ServerToolSet {
  RecordingToolSet({
    required this.terminals,
    required this.registry,
    required this.recordingsDirectory,
    required this.readyDevices,
    required this.heldBy,
    required this.adb,
    SimctlService? Function()? simctl,
    DeviceRecorder? recorder,
  }) : recorder =
           recorder ??
           DeviceRecorder(
             clock: const SystemClock(),
             recordingDirectory: () async {
               await Directory(recordingsDirectory).create(recursive: true);
               return recordingsDirectory;
             },
             simctl: simctl ?? () => null,
           );

  /// Over the server's own devices and claims.
  factory RecordingToolSet.over({
    required ServerTerminals terminals,
    required SessionRegistry registry,
    required String recordingsDirectory,
    required ServerDevices devices,
  }) => RecordingToolSet(
    terminals: terminals,
    registry: registry,
    recordingsDirectory: recordingsDirectory,
    readyDevices: () async => (await devices.fleet()).ready(),
    heldBy: (sessionId) => {
      for (final claim in devices.claims.registry.held)
        if (claim.holderSessionId == sessionId) claim.deviceId,
    },
    adb: devices.adb,
    simctl: () => devices.simctl,
  );

  final ServerTerminals terminals;
  final SessionRegistry registry;

  /// `<data dir>/recordings`.
  final String recordingsDirectory;

  /// The devices on this machine that are ready to record.
  final Future<List<DeviceTarget>> Function() readyDevices;

  /// The devices session [sessionId] holds a claim on.
  final Set<String> Function(String? sessionId) heldBy;
  final Future<AdbService?> Function() adb;
  final DeviceRecorder recorder;

  final _casts = <String, TerminalCastRecorder>{};

  static const _names = {
    'terminal_record_start',
    'terminal_record_stop',
    'device_record_start',
    'device_record_stop',
  };

  @override
  List<Map<String, Object?>> get schemas => recordingControlToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (!_names.contains(tool)) return null;
    return runTool(
      () => switch (tool) {
        'terminal_record_start' => _terminalStart(
          arguments['paneId'] as String?,
        ),
        'terminal_record_stop' => _terminalStop(
          arguments['paneId'] as String?,
          arguments['format'] as String?,
        ),
        'device_record_start' => _deviceStart(
          arguments['format'] as String?,
          callerSessionId,
        ),
        _ => _deviceStop(),
      },
    );
  }

  /// The terminal pane [paneId] names, as the server runs it.
  ({HostSession session, String title})? _terminal(String paneId) {
    for (final record in terminals.records) {
      if (record.paneId != paneId) continue;
      final session = registry.find(record.sessionId);
      return session == null ? null : (session: session, title: record.title);
    }
    final hosted = registry.find('karmashala_local_$paneId');
    if (hosted == null) return null;
    return (session: hosted, title: hosted.facts?.title ?? paneId);
  }

  static const _formatsNote =
      'The server writes an asciicast (.cast); a Karmashala window renders one '
      'to MP4, GIF or pictures.';

  Object? _terminalStart(String? paneId) {
    if (paneId == null || paneId.isEmpty) {
      throw ArgumentError('paneId is required. Use terminal_list to find one.');
    }
    final terminal = _terminal(paneId);
    if (terminal == null) {
      throw ArgumentError(
        'No terminal pane $paneId. Use terminal_list, or terminal_open to '
        'make one.',
      );
    }
    if (_casts.containsKey(paneId)) {
      return <String, Object?>{
        'recording': paneId,
        'note': 'Already recording this pane.',
        'formats': const ['cast'],
        'formatsNote': _formatsNote,
      };
    }
    if (terminal.session.lifecycle.hasEnded) {
      throw StateError(
        'Pane $paneId is not live, so there is nothing to record.',
      );
    }
    _casts[paneId] = TerminalCastRecorder.start(
      terminal.session,
      title: terminal.title,
    );
    return <String, Object?>{
      'recording': paneId,
      'note':
          'The Karmashala server is recording everything printed in this pane '
          'from now on, secrets included. Call terminal_record_stop to end it '
          'and get a file.',
      'formats': const ['cast'],
      'formatsNote': _formatsNote,
    };
  }

  Future<Object?> _terminalStop(String? paneId, String? format) async {
    if (paneId == null || paneId.isEmpty) {
      throw ArgumentError('paneId is required.');
    }
    final asked = _formatOf(format);
    final cast = _casts.remove(paneId);
    if (cast == null) {
      throw StateError('Pane $paneId was not being recorded.');
    }
    final file = await cast.stop(recordingsDirectory);
    final notMade = asked == null || asked == 'cast'
        ? ''
        : ' $asked was NOT produced: the server does not render video; a '
              'Karmashala window renders a cast to MP4, GIF or pictures.';
    return <String, Object?>{
      'file': file.path,
      'format': 'cast',
      'isVideo': false,
      'bytes': await file.length(),
      'seconds': cast.duration.inMilliseconds / 1000,
      'cast': file.path,
      'endedWithPane': cast.sourceEnded,
      'note':
          'An asciicast v2 file — the pane\'s own bytes with their timing, '
          'which asciinema plays as it is. It is not a video.$notMade',
    };
  }

  /// The format a caller named, in the app's words; null for none.
  static String? _formatOf(String? asked) {
    if (asked == null || asked.isEmpty) return null;
    return switch (asked.toLowerCase()) {
      'mp4' => 'mp4',
      'gif' => 'gif',
      'png' || 'pngsequence' || 'frames' => 'pngSequence',
      'cast' => 'cast',
      _ => throw ArgumentError('format must be "mp4", "gif" or "pngSequence".'),
    };
  }

  Future<Object?> _deviceStart(String? format, String? callerSessionId) async {
    switch ((format ?? '').toLowerCase()) {
      case '' || 'mp4':
        break;
      case 'ts' || 'mpegts' || 'transportstream':
        throw StateError(
          'MPEG-TS is what a device pane\'s live view records, in a window. '
          'The server records a device with the device\'s own recorder, which '
          'writes MP4 (Android) or a QuickTime movie (a simulator). Ask for '
          '"mp4", or leave format out.',
        );
      default:
        throw ArgumentError('format must be "mp4" or "ts".');
    }
    final before = recorder.state;
    if (before is DeviceRecordingActive) {
      throw StateError(
        'Already recording ${before.target.id} to ${before.path}. One at a '
        'time; call device_record_stop first.',
      );
    }
    final target = await _deviceFor(callerSessionId);
    switch (target) {
      case final AndroidTarget android:
        final service = await adb();
        if (service == null) {
          throw StateError(
            'No Android SDK is on the Karmashala server\'s machine, so its adb '
            'cannot record ${android.id}.',
          );
        }
        await recorder.startScreenRecord(android, service);
      case final SimulatorTarget simulator:
        await recorder.startSimulatorRecording(simulator);
    }
    final now = recorder.state;
    if (now is! DeviceRecordingActive) {
      final last = now is DeviceRecordingIdle ? now.last : null;
      throw StateError(
        last?.message ?? 'The recording of ${target.id} did not start.',
      );
    }
    return <String, Object?>{
      'recording': now.target.id,
      'file': now.path,
      'format': target is AndroidTarget ? 'mp4' : 'mov',
      'note': target is AndroidTarget
          ? 'The device records itself with screenrecord, for at most 180 '
                'seconds — then it stops on its own and the recording ends '
                'early. Call device_record_stop to end it and get the file.'
          : 'simctl is recording the simulator. Call device_record_stop to '
                'end it and get the file.',
    };
  }

  /// The device a recording is of: the one the caller holds, else the only
  /// one ready; refused in words otherwise.
  Future<DeviceTarget> _deviceFor(String? callerSessionId) async {
    final ready = await readyDevices();
    final held = heldBy(callerSessionId);
    final mine = [
      for (final target in ready)
        if (held.contains(target.id)) target,
    ];
    if (mine.length == 1) return mine.single;
    if (ready.length == 1) return ready.single;
    if (ready.isEmpty) {
      throw StateError(
        'No device is ready on the Karmashala server\'s machine, so there is '
        'nothing to record. list_devices shows what is there.',
      );
    }
    throw StateError(
      'More than one device is ready (${ready.map((t) => t.id).join(', ')}) '
      'and this session holds none of them. Use one first — any device_* call '
      'claims it — then record.',
    );
  }

  Future<Object?> _deviceStop() async {
    if (recorder.state is! DeviceRecordingActive) {
      throw StateError('No device recording is running.');
    }
    await recorder.stop();
    final state = recorder.state;
    final outcome = state is DeviceRecordingIdle ? state.last : null;
    if (outcome == null) throw StateError('The recording wrote no outcome.');
    return <String, Object?>{
      'result': outcome.result.name,
      'file': ?outcome.path,
      'isVideo': outcome.result == DeviceRecordingResult.saved,
      'note': outcome.message,
    };
  }

  /// Stops every recording without writing: the server is going away.
  Future<void> close() async {
    for (final cast in _casts.values) {
      await cast.abandon();
    }
    _casts.clear();
    await recorder.abandon();
  }
}
