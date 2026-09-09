import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/media/video_support_provider.dart';
import 'package:karmashala_core/media.dart';
import 'package:karmashala/src/features/terminal/application/terminal_recording_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/recording_saved_dialog.dart';
import 'package:karmashala/src/features/terminal/presentation/session_status.dart';

import 'fake_instance.dart';

/// The two things the chrome has to get right: a running recording is on
/// screen for as long as it runs and can be stopped from where it is said, and
/// nothing claims to have made a video the user's player can open when it has
/// not.
///
/// Writing the cast is real file I/O, which a `testWidgets` clock does not
/// advance — so every stop below is started inside [WidgetTester.runAsync]
/// rather than awaited through a number of pumps that would look like a hang.
void main() {
  late ProviderContainer container;
  late AppDatabase db;
  late Directory temp;

  /// Both surfaces read the same reading, so both cases are testable on any
  /// host rather than only on the one that happens to have an encoder.
  void build({required VideoSupport support}) {
    temp = Directory.systemTemp.createTempSync('recording-ui');
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        recordingsDirectoryProvider.overrideWith((ref) async => temp),
        videoSupportProvider.overrideWithValue(support),
      ],
    );
  }

  setUp(
    () => build(
      support: const VideoSupport.available('the test host writes MP4.'),
    ),
  );
  tearDown(() {
    container.dispose();
    db.close();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle a moment longer; not what this file is about.
    }
  });

  TerminalRecordingController recording() =>
      container.read(terminalRecordingProvider.notifier);

  FakeTerminalInstance pane(String paneId) =>
      container
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId)!
          as FakeTerminalInstance;

  Future<String> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pump();
    return container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
  }

  testWidgets('a recording pane says so, for as long as it records', (
    tester,
  ) async {
    final paneId = await mount(tester);
    expect(
      find.byType(PaneRecordingBanner),
      findsNothing,
      reason: 'an idle pane costs the chrome nothing',
    );

    recording().start(paneId);
    await tester.pump();

    expect(find.byType(PaneRecordingBanner), findsOneWidget);
    expect(
      find.textContaining('everything on this screen is being captured'),
      findsOneWidget,
    );
    expect(find.text('Stop recording'), findsOneWidget);
  });

  testWidgets('the banner stops it, and the pane is released at the tap', (
    tester,
  ) async {
    final paneId = await mount(tester);
    recording().start(paneId);
    await tester.pump();
    pane(paneId).receive('captured\r\n');

    await tester.tap(find.text('Stop recording'));
    await tester.pump();

    expect(
      container.read(terminalRecordingProvider).isRecording(paneId),
      isFalse,
      reason: 'the pane is released at the tap, before the write',
    );
    expect(find.byType(PaneRecordingBanner), findsNothing);
    // The write the tap started. It cannot be awaited from here — a stop begun
    // inside a `testWidgets` clock never reaches its file I/O — so what this
    // asserts is that the banner really stopped rather than only disappeared.
    // What ends up in the file is `terminal_recording_test.dart`'s subject.
    expect(recording().pendingSave, isNotNull);
  });

  group('the dialog', () {
    /// Records [output], stops, and leaves the dialog on screen.
    Future<void> open(
      WidgetTester tester,
      String paneId,
      String output,
    ) async {
      recording().start(paneId);
      await tester.pump();
      pane(paneId).receive(output);
      await tester.runAsync(() => recording().stop(paneId));
      await tester.pump();
      unawaited(
        showRecordingSavedDialog(tester.element(find.byType(WorkbenchView))),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says where the recording went and what is in it', (
      tester,
    ) async {
      final paneId = await mount(tester);
      await open(tester, paneId, 'AWS_SECRET_ACCESS_KEY=hunter2\r\n');

      final saved = container.read(terminalRecordingProvider).saved!;
      expect(find.text(saved.file.path), findsOneWidget);

      // A cast cannot be redacted and the dialog must not imply that it was.
      expect(
        find.textContaining('including anything secret that was printed there'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing was removed'), findsOneWidget);
    });

    testWidgets('offers GIF and MP4, and neither asks for a tool', (
      tester,
    ) async {
      final paneId = await mount(tester);
      await open(tester, paneId, 'ok\r\n');

      expect(find.text('Render GIF'), findsOneWidget);
      expect(find.textContaining('Plays anywhere as it is'), findsOneWidget);
      expect(find.text('Render MP4'), findsOneWidget);
      expect(
        find.textContaining('nothing to run afterwards'),
        findsOneWidget,
      );
      // The frame sequence is gone where a real video can be written, and with
      // it the sentence about a tool we do not ship.
      expect(find.text('Render frames'), findsNothing);
      expect(
        find.textContaining('This app does not bundle ffmpeg'),
        findsNothing,
      );
    });

    testWidgets('with no encoder it says why and falls back to frames', (
      tester,
    ) async {
      container.dispose();
      db.close();
      build(
        support: const VideoSupport.unavailable(
          'MP4 needs an encoder from the operating system, and only the '
          'Windows one is wired up here.',
        ),
      );
      final paneId = await mount(tester);
      await open(tester, paneId, 'ok\r\n');

      // §19: which format is missing and why, before anything is rendered.
      expect(
        find.textContaining('needs an encoder from the operating system'),
        findsOneWidget,
      );
      expect(find.text('Render MP4'), findsNothing);
      expect(find.text('Render frames'), findsOneWidget);
      expect(
        find.textContaining('This app does not bundle ffmpeg'),
        findsOneWidget,
      );
    });

    testWidgets('done puts the recording away', (tester) async {
      final paneId = await mount(tester);
      await open(tester, paneId, 'ok\r\n');

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(container.read(terminalRecordingProvider).saved, isNull);
    });
  });
}
