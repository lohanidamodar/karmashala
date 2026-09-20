import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_media/media.dart';
import 'package:karmashala/src/core/media/video_support_provider.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/recording_tools.dart';
import 'package:karmashala/src/features/terminal/application/terminal_recording_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../terminal/fake_instance.dart';

/// Recording as an agent drives it: start, stop, get a file, choose the format
/// — and be told which formats exist here before asking for one that does not.
///
/// **This file used to take the tester process down under load**, because
/// probing the MP4 encoder loaded the GPU vendors' Media Foundation transforms
/// into the test process. Both the probe and the render below now ask for the
/// software encoder; the crash, the fix and the before/after measurement are
/// recorded once, in `test/core/media/video_writer_test.dart`.
void main() {
  // `Picture.toImage` needs a binding; a real render runs below.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late Directory temp;

  void build({required VideoSupport support}) {
    temp = Directory.systemTemp.createTempSync('rec-tools');
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        recordingsDirectoryProvider.overrideWith((ref) async => temp),
        videoSupportProvider.overrideWithValue(support),
        // The MP4 case below renders through the app's own path; this is what
        // keeps the vendor encoder MFTs out of the tester.
        hardwareTransformsProvider.overrideWithValue(false),
      ],
    );
  }

  /// Stops anything still recording before the container goes.
  ///
  /// Disposing with a recording open ends the pane, which writes its cast in a
  /// microtask — after the temp directory has been deleted.
  Future<void> retire() async {
    final recording = container.read(terminalRecordingProvider.notifier);
    for (final paneId
        in container.read(terminalRecordingProvider).active.keys.toList()) {
      await recording.stop(paneId);
    }
    container.dispose();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the handle a moment longer.
    }
  }

  setUp(
    () => build(support: const VideoSupport.available('this host writes MP4.')),
  );

  tearDown(retire);

  RecordingControlTools tools() => RecordingControlTools(container);

  String openPane() {
    final sessions = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = sessions.openTab(TerminalProfile.powerShell);
    return container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((candidate) => candidate.id == tab)
        .layout
        .panes
        .single;
  }

  group('tool registration', () {
    test('every recording tool is advertised and dispatchable', () {
      final names = recordingControlToolSchemas
          .map((schema) => schema['name'] as String)
          .toList();
      expect(names, [
        'terminal_record_start',
        'terminal_record_stop',
        'device_record_start',
        'device_record_stop',
      ]);
      for (final name in names) {
        expect(RecordingControlTools.handles(name), isTrue, reason: name);
        expect(
          LauncherControlServer.toolSchemas.any(
            (schema) => schema['name'] == name,
          ),
          isTrue,
          reason: '$name is not served',
        );
      }
    });

    test('each schema is a well-formed object schema', () {
      for (final schema in recordingControlToolSchemas) {
        expect(schema['description'], isA<String>());
        expect((schema['description'] as String).length, greaterThan(40));
        final input = schema['inputSchema'] as Map<String, dynamic>;
        expect(input['type'], 'object');
        final properties = input['properties'] as Map<String, dynamic>;
        for (final required in (input['required'] as List? ?? const [])) {
          expect(properties.containsKey(required), isTrue, reason: '$required');
        }
      }
    });
  });

  group('terminal_record_start', () {
    test('says what the formats are before anything is recorded', () async {
      final paneId = openPane();
      final answer =
          await tools().call('terminal_record_start', {'paneId': paneId})
              as Map<String, Object?>;

      expect(answer['recording'], paneId);
      expect(answer['formats'], ['gif', 'mp4']);
      expect(answer.containsKey('mp4Unavailable'), isFalse);
      // The agent is told what it is capturing, in the tool's own answer.
      expect(answer['note'], contains('secrets included'));
      expect(
        container.read(terminalRecordingProvider).isRecording(paneId),
        isTrue,
      );
    });

    test('with no encoder it offers frames and says why', () async {
      await retire();
      build(
        support: const VideoSupport.unavailable('no encoder on this host.'),
      );
      final paneId = openPane();
      final answer =
          await tools().call('terminal_record_start', {'paneId': paneId})
              as Map<String, Object?>;

      expect(answer['formats'], ['gif', 'pngSequence']);
      expect(answer['mp4Unavailable'], 'no encoder on this host.');
    });

    test('an unknown pane is refused rather than silently ignored', () {
      expect(
        () => tools().call('terminal_record_start', {'paneId': 'nope'}),
        throwsArgumentError,
      );
    });
  });

  group('terminal_record_stop', () {
    test('renders a GIF and reports it as a video', () async {
      final paneId = openPane();
      await tools().call('terminal_record_start', {'paneId': paneId});
      (container
                  .read(terminalSessionsControllerProvider.notifier)
                  .instanceFor(paneId)!
              as FakeTerminalInstance)
          .receive('hello from the agent\r\n');

      final answer =
          await tools().call('terminal_record_stop', {
                'paneId': paneId,
                'format': 'gif',
              })
              as Map<String, Object?>;

      expect(answer['format'], 'gif');
      expect(answer['isVideo'], isTrue);
      expect(answer['frames'], greaterThan(0));
      expect(answer['bytes'], greaterThan(0));
      expect(answer['file'], endsWith('.gif'));
      expect(File(answer['file']! as String).existsSync(), isTrue);
      // The cast is named too, because it can be rendered again.
      expect(answer['cast'], endsWith('.cast'));
    });

    test('renders a real MP4 an agent can hand straight over', () async {
      await retire();
      // The host's own reading, not an override: this is the whole claim.
      build(support: probeVideoSupport(hardwareTransforms: false));
      final paneId = openPane();
      final started =
          await tools().call('terminal_record_start', {'paneId': paneId})
              as Map<String, Object?>;
      expect(started['formats'], contains('mp4'));
      (container
                  .read(terminalSessionsControllerProvider.notifier)
                  .instanceFor(paneId)!
              as FakeTerminalInstance)
          .receive('an agent recorded this\r\n');

      // No format asked for: MP4 is the default where it can be written.
      final answer =
          await tools().call('terminal_record_stop', {'paneId': paneId})
              as Map<String, Object?>;

      expect(answer['format'], 'mp4');
      expect(answer['isVideo'], isTrue);
      expect(answer['note'], contains('opens in a player as it is'));
      final file = File(answer['file']! as String);
      expect(file.path, endsWith('.mp4'));
      // A real MP4, not a name: the box every player looks for first.
      expect(
        String.fromCharCodes(file.readAsBytesSync().sublist(4, 8)),
        'ftyp',
      );
      expect(answer['bytes'], file.lengthSync());
    }, skip: !Platform.isWindows);

    test('asking for MP4 where it cannot be written refuses first', () async {
      await retire();
      build(
        support: const VideoSupport.unavailable('only Windows is wired up.'),
      );
      final paneId = openPane();
      await tools().call('terminal_record_start', {'paneId': paneId});

      await expectLater(
        tools().call('terminal_record_stop', {
          'paneId': paneId,
          'format': 'mp4',
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('only Windows is wired up'),
          ),
        ),
      );
      // Refused *before* the recording was stopped, so nothing was lost.
      expect(
        container.read(terminalRecordingProvider).isRecording(paneId),
        isTrue,
      );
    });

    test('a nonsense format is named rather than guessed at', () async {
      final paneId = openPane();
      await tools().call('terminal_record_start', {'paneId': paneId});
      expect(
        () => tools().call('terminal_record_stop', {
          'paneId': paneId,
          'format': 'webm',
        }),
        throwsArgumentError,
      );
    });

    test('a pane that was not recording is refused', () async {
      final paneId = openPane();
      await expectLater(
        tools().call('terminal_record_stop', {'paneId': paneId}),
        throwsStateError,
      );
    });
  });

  group('device_record_start', () {
    test('with no live view it says so instead of claiming a recording', () {
      expect(
        () => tools().call('device_record_start', {'format': 'mp4'}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('No device live view is running'),
          ),
        ),
      );
    });

    test('MP4 where it cannot be written is refused with the reason', () async {
      await retire();
      build(support: const VideoSupport.unavailable('no encoder here.'));
      expect(
        () => tools().call('device_record_start', {'format': 'mp4'}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('no encoder here'),
          ),
        ),
      );
    });

    test('an unknown container is named', () {
      expect(
        () => tools().call('device_record_start', {'format': 'mkv'}),
        throwsArgumentError,
      );
    });
  });

  test('device_record_stop with nothing running is refused', () {
    expect(() => tools().call('device_record_stop', {}), throwsStateError);
    expect(container.read(deviceRecordingProvider), isNotNull);
  });
}
