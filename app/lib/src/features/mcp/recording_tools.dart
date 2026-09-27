import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_media/media.dart';
import '../../core/media/video_support_provider.dart';
import 'package:karmashala_device_pane/providers.dart';
import '../terminal/application/terminal_recording_controller.dart';
import '../terminal/application/terminal_sessions_controller.dart';

/// Recording a pane or a device, through the controllers the menus call — same
/// banner, same folder, and stoppable by the person beside it.
class RecordingControlTools {
  RecordingControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{
    'terminal_record_start',
    'terminal_record_stop',
    'device_record_start',
    'device_record_stop',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'terminal_record_start' => _terminalStart(args['paneId'] as String?),
        'terminal_record_stop' => _terminalStop(
          args['paneId'] as String?,
          args['format'] as String?,
        ),
        'device_record_start' => _deviceStart(args['format'] as String?),
        'device_record_stop' => _deviceStop(),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  TerminalRecordingController get _terminal =>
      _container.read(terminalRecordingProvider.notifier);

  /// What can be produced here, and why not, when it cannot: returned by both
  /// start tools, so the choice is known before the recording runs.
  Map<String, Object?> _formats(List<String> offered) {
    final support = _container.read(videoSupportProvider);
    return <String, Object?>{
      'formats': offered,
      if (!support.available) 'mp4Unavailable': support.detail,
    };
  }

  Future<Object?> _terminalStart(String? paneId) async {
    if (paneId == null || paneId.isEmpty) {
      throw ArgumentError('paneId is required. Use terminal_list to find one.');
    }
    final sessions = _container.read(
      terminalSessionsControllerProvider.notifier,
    );
    if (sessions.instanceFor(paneId) == null) {
      throw ArgumentError(
        'No terminal pane $paneId. Use terminal_list, or terminal_open to '
        'make one.',
      );
    }
    final state = _container.read(terminalRecordingProvider);
    if (state.isRecording(paneId)) {
      return <String, Object?>{
        'recording': paneId,
        'note': 'Already recording this pane.',
        ..._formats(_terminalFormats()),
      };
    }
    if (!_terminal.start(paneId)) {
      throw StateError(
        'Pane $paneId is not live, so there is nothing to record.',
      );
    }
    return <String, Object?>{
      'recording': paneId,
      'note':
          'The pane says it is being recorded and the user can stop it. '
          'Everything printed there is captured, secrets included. '
          'Call terminal_record_stop to end it and get a file.',
      ..._formats(_terminalFormats()),
    };
  }

  List<String> _terminalFormats() => <String>[
    RecordingFormat.gif.name,
    if (_container.read(videoSupportProvider).available)
      RecordingFormat.mp4.name
    else
      'pngSequence',
  ];

  Future<Object?> _terminalStop(String? paneId, String? format) async {
    if (paneId == null || paneId.isEmpty) {
      throw ArgumentError('paneId is required.');
    }
    final support = _container.read(videoSupportProvider);
    // Resolved before the recording is stopped: a refusal after the fact would
    // leave the cast written and the caller with no file and no way back.
    final wanted = _resolveTerminalFormat(format, support.available);
    if (wanted == RecordingFormat.mp4 && !support.available) {
      throw StateError('MP4 cannot be written here. ${support.detail}');
    }
    final saved = await _terminal.stop(paneId);
    if (saved == null) {
      throw StateError('Pane $paneId was not being recorded.');
    }
    await _terminal.render(
      saved,
      format: wanted,
      style: TerminalRecordingController.styleFor(
        format: wanted,
        cast: saved.cast,
      ),
    );
    final export = _container.read(terminalRecordingProvider).export;
    if (export?.error case final failure?) {
      throw StateError('Rendering the recording failed: $failure');
    }
    final result = export?.result;
    if (result == null) throw StateError('The render produced nothing.');
    return <String, Object?>{
      'file': result.path,
      'format': wanted.name,
      // §19: a file of pictures never claims to be a video.
      'isVideo': !result.needsExternalTool,
      'frames': result.frames,
      'bytes': result.bytes,
      'seconds': saved.cast.duration.inMilliseconds / 1000,
      'cast': saved.file.path,
      'note': result.needsExternalTool
          ? 'These are numbered PNGs, not a video. '
                '${result.externalCommand} turns them into an MP4, and this '
                'app does not bundle ${result.externalTool}.'
          : 'A finished ${wanted.extension.toUpperCase()} — it opens in a '
                'player as it is. The .cast beside it can be rendered again '
                'at another size.',
    };
  }

  RecordingFormat _resolveTerminalFormat(String? asked, bool mp4Available) {
    if (asked == null || asked.isEmpty) {
      return mp4Available ? RecordingFormat.mp4 : RecordingFormat.gif;
    }
    return switch (asked.toLowerCase()) {
      'mp4' => RecordingFormat.mp4,
      'gif' => RecordingFormat.gif,
      'png' || 'pngsequence' || 'frames' => RecordingFormat.pngSequence,
      _ => throw ArgumentError('format must be "mp4", "gif" or "pngSequence".'),
    };
  }

  Future<Object?> _deviceStart(String? format) async {
    final support = _container.read(videoSupportProvider);
    final container = switch ((format ?? '').toLowerCase()) {
      '' =>
        support.available
            ? DeviceRecordingContainer.mp4
            : DeviceRecordingContainer.transportStream,
      'mp4' => DeviceRecordingContainer.mp4,
      'ts' ||
      'mpegts' ||
      'transportstream' => DeviceRecordingContainer.transportStream,
      _ => throw ArgumentError('format must be "mp4" or "ts".'),
    };
    if (container == DeviceRecordingContainer.mp4 && !support.available) {
      throw StateError('MP4 cannot be written here. ${support.detail}');
    }
    final recorder = _container.read(deviceRecordingProvider.notifier);
    final before = _container.read(deviceRecordingProvider);
    if (before is DeviceRecordingActive) {
      throw StateError(
        'Already recording ${before.target.id} to ${before.path}. One at a '
        'time; call device_record_stop first.',
      );
    }
    await recorder.startLiveViewRecording(container: container);
    final now = _container.read(deviceRecordingProvider);
    if (now is! DeviceRecordingActive) {
      // The recorder writes the frames the live picture is made of, so there is
      // nothing to record without one.
      throw StateError(
        'No device live view is running, so there are no frames to record. '
        'Open a device pane and start its live view first.',
      );
    }
    return <String, Object?>{
      'recording': now.target.id,
      'file': now.path,
      'format': container.name,
      'note':
          'The device pane says it is recording and the user can stop it. '
          'Call device_record_stop to end it.',
      ..._formats(<String>['mp4', 'ts']),
    };
  }

  Future<Object?> _deviceStop() async {
    final recorder = _container.read(deviceRecordingProvider.notifier);
    if (_container.read(deviceRecordingProvider) is! DeviceRecordingActive) {
      throw StateError('No device recording is running.');
    }
    await recorder.stop();
    final state = _container.read(deviceRecordingProvider);
    final outcome = state is DeviceRecordingIdle ? state.last : null;
    if (outcome == null) throw StateError('The recording wrote no outcome.');
    return <String, Object?>{
      'result': outcome.result.name,
      'file': ?outcome.path,
      // Every one of these is real video off the handset's own encoder; the
      // empty and failed outcomes have no file at all.
      'isVideo': outcome.result == DeviceRecordingResult.saved,
      'note': outcome.message,
    };
  }
}

const List<Map<String, dynamic>> recordingControlToolSchemas = [
  {
    'name': 'terminal_record_start',
    'description':
        'Start recording a terminal pane. The pane shows a banner for as long '
        'as it records and the user can stop it. Everything printed in the '
        'pane is captured, including anything secret — nothing is redacted. '
        'Answers with the formats terminal_record_stop can produce on this '
        'machine, so ask for one that exists.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description': 'From terminal_list, or terminal_open.',
        },
      },
      'required': ['paneId'],
    },
  },
  {
    'name': 'terminal_record_stop',
    'description':
        'Stop a terminal recording and render it to a file. "mp4" is a '
        'finished 1920x1080 video written by the operating system\'s own '
        'encoder; "gif" is 960x540 and 256 colours and plays anywhere; '
        '"pngSequence" is numbered pictures plus an ffmpeg command this app '
        'does not bundle. Defaults to mp4 where it can be written, gif where '
        'it cannot. Answers with the file, and with isVideo=false when what it '
        'wrote is pictures rather than a video.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {'type': 'string'},
        'format': {
          'type': 'string',
          'description': '"mp4", "gif" or "pngSequence".',
        },
      },
      'required': ['paneId'],
    },
  },
  {
    'name': 'device_record_start',
    'description':
        'Start recording the screen of the device whose live view is running. '
        'Needs that live view: the recording is written from the frames the '
        'picture is made of, and there is nothing to record without one. '
        '"mp4" is the file every player opens; "ts" is MPEG-TS, the only one '
        'that survives the device rotating mid-recording. Neither re-encodes — '
        'both hold the handset\'s own H.264.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'format': {'type': 'string', 'description': '"mp4" or "ts".'},
      },
    },
  },
  {
    'name': 'device_record_stop',
    'description':
        'Stop the device screen recording and say what became of it — the '
        'file, or why there is none. A recording that caught no frame reports '
        '"empty" and leaves no file behind rather than a container header no '
        'player opens.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
];
