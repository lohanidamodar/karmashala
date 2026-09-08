import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/media/frame_sink.dart';
import 'package:karmashala/src/features/terminal/application/terminal_recording_controller.dart';
import 'package:karmashala/src/features/terminal/data/cast_frame_renderer.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/ingest_tier.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_cast.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:path/path.dart' as p;
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// A recording is a long-lived side effect, and the two things that break one
/// are the two things this file is about: it must not stop when the user looks
/// somewhere else, and it must not vanish when the pane does.
void main() {
  // `Picture.toImage` needs a binding; the render case below paints real frames.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late TerminalSessionsController sessions;
  late TerminalRecordingController recording;
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('recordings');
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        recordingsDirectoryProvider.overrideWith((ref) async => temp),
      ],
    );
    sessions = container.read(terminalSessionsControllerProvider.notifier);
    recording = container.read(terminalRecordingProvider.notifier);
  });

  tearDown(() {
    container.dispose();
    // Windows refuses to delete a directory a handle is still open on, and a
    // leftover temp folder is not what any of these tests is about.
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  FakeTerminalInstance pane(String paneId) =>
      sessions.instanceFor(paneId)! as FakeTerminalInstance;

  String openPane() {
    final tab = sessions.openTab(TerminalProfile.powerShell);
    return container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == tab)
        .layout
        .panes
        .single;
  }

  test('records the output a pane produces while it is running', () async {
    final paneId = openPane();
    expect(recording.start(paneId), isTrue);
    expect(container.read(terminalRecordingProvider).isRecording(paneId), isTrue);

    pane(paneId).receive('PS> flutter test\r\n');
    pane(paneId).receive('All tests passed!\r\n');

    final saved = (await recording.stop(paneId))!;
    expect(
      saved.cast.events.map((e) => e.data).join(),
      contains('All tests passed!'),
    );
    expect(saved.cast.events.every((e) => e.kind == CastEventKind.output), isTrue);
    expect(container.read(terminalRecordingProvider).isRecording(paneId), isFalse);
  });

  test('keeps recording a pane the user has switched away from', () async {
    final paneId = openPane();
    recording.start(paneId);
    pane(paneId).receive('before the switch\r\n');

    // Another tab in front demotes this pane, and cold is where its bytes stop
    // reaching the buffer at all. The recording tap is upstream of that.
    sessions.openTab(TerminalProfile.commandPrompt);
    pane(paneId).setIngestTier(IngestTier.cold);
    expect(pane(paneId).ingestTier, IngestTier.cold);
    pane(paneId).receive('while nobody was looking\r\n');

    final saved = (await recording.stop(paneId))!;
    final text = saved.cast.events.map((e) => e.data).join();
    expect(text, contains('before the switch'));
    expect(
      text,
      contains('while nobody was looking'),
      reason: 'a cold pane never writes to its buffer; the tap is before that',
    );
  });

  test('a resize mid-recording is recorded as a resize', () async {
    final paneId = openPane();
    recording.start(paneId);
    pane(paneId).receive('narrow\r\n');
    pane(paneId).resizeGrid(120, 40);
    pane(paneId).receive('wide\r\n');

    final saved = (await recording.stop(paneId))!;
    final resizes = saved.cast.events
        .where((e) => e.kind == CastEventKind.resize)
        .toList();
    expect(resizes.single.grid, (columns: 120, rows: 40));
    // The frame a renderer has to cut is the widest the grid ever was.
    expect(saved.cast.widestGrid, (columns: 120, rows: 40));
  });

  test('writes the cast the moment recording stops, and says where', () async {
    final paneId = openPane();
    recording.start(paneId);
    pane(paneId).receive('hello\r\n');

    final saved = (await recording.stop(paneId))!;
    expect(saved.file.existsSync(), isTrue);
    expect(p.dirname(saved.file.path), temp.path);
    expect(p.extension(saved.file.path), '.cast');

    // And it is the documented format, not a blob only this app can read.
    final decoded = decodeCast(saved.file.readAsStringSync());
    expect(decoded.events.map((e) => e.data).join(), contains('hello'));
    expect(container.read(terminalRecordingProvider).saved, same(saved));
  });

  test('a pane closed mid-recording still hands over what it captured', () async {
    final paneId = openPane();
    recording.start(paneId);
    pane(paneId).receive('the last thing it said\r\n');

    sessions.closePane(paneId);
    // The pane ended the recording from inside `dispose()`, which could not
    // await the write — so wait on the save it started rather than on a clock.
    await recording.pendingSave;

    final state = container.read(terminalRecordingProvider);
    expect(state.isRecording(paneId), isFalse);
    expect(state.saved, isNotNull);
    expect(state.saved!.endedWithPane, isTrue);
    expect(
      state.saved!.cast.events.map((e) => e.data).join(),
      contains('the last thing it said'),
    );
    expect(state.saved!.file.existsSync(), isTrue);
  });

  test('starting twice on one pane changes nothing', () async {
    final paneId = openPane();
    expect(recording.start(paneId), isTrue);
    expect(recording.start(paneId), isFalse);
    pane(paneId).receive('once\r\n');

    final saved = (await recording.stop(paneId))!;
    expect(saved.cast.events.map((e) => e.data).join(), 'once\r\n');
  });

  test('stopping a pane that was never recording is not an event', () async {
    expect(await recording.stop('nothing-here'), isNull);
    expect(container.read(terminalRecordingProvider).saved, isNull);
  });

  test('renders a saved recording into a GIF beside its cast', () async {
    final paneId = openPane();
    recording.start(paneId);
    pane(paneId).receive('PS> flutter test\r\nAll tests passed!\r\n');
    final saved = (await recording.stop(paneId))!;

    await recording.render(
      saved,
      format: RecordingFormat.gif,
      style: CastFrameStyle(
        width: 160,
        height: 96,
        theme: TerminalThemes.defaultTheme,
        fontFamily: 'monospace',
        title: 'pwsh',
      ),
    );

    final export = container.read(terminalRecordingProvider).export!;
    expect(export.error, isNull);
    final result = export.result!;
    expect(result.frames, greaterThan(0));
    expect(export.rendered, result.frames);
    expect(
      export.progress,
      1.0,
      reason: 'the bar reaches the end it was given, not a guess at one',
    );

    // The GIF is beside the cast, is a GIF, and needs no tool to open.
    expect(result.path, '${p.withoutExtension(saved.file.path)}.gif');
    expect(result.needsExternalTool, isFalse);
    final bytes = File(result.path).readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(6)), 'GIF89a');
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('recordingFileName', () {
    test('carries the pane title and when it started', () {
      expect(
        recordingFileName('pwsh', DateTime(2026, 9, 8, 14, 30, 5)),
        'pwsh-20260908-143005.cast',
      );
    });

    test('squeezes a title a shell can call anything into a file name', () {
      expect(
        recordingFileName(r'C:\Users\me — claude: build?', DateTime(2026, 1, 2)),
        'C-Users-me-claude-build-20260102-000000.cast',
      );
      expect(
        recordingFileName('///', DateTime(2026, 1, 2)),
        'terminal-20260102-000000.cast',
      );
      expect(
        recordingFileName(null, DateTime(2026, 1, 2)),
        'terminal-20260102-000000.cast',
      );
      expect(
        recordingFileName('x' * 90, DateTime(2026, 1, 2)),
        '${'x' * 40}-20260102-000000.cast',
      );
    });
  });
}
