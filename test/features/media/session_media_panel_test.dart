import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';
import 'package:karmashala/src/features/media/presentation/session_media_list.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_image_preview.dart';

import '../../support/window_matrix.dart';
import '../../support/temp_directory.dart';

/// The panel the owner asked for: *"a media sidebar that shows all the media
/// from current session in descending order"*.
///
/// The list is a plain widget over plain items — the scan that produces them is
/// tested next door — so every case below is one the real store produces: a
/// file the agent read, a picture the user pasted, a screenshot a tool
/// returned, and the four ways each of those can fail to be drawable.
void main() {
  late Directory dir;

  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  setUp(() => dir = Directory.systemTemp.createTempSync('media_panel'));
  tearDown(() => removeTempDirectory(dir));

  File writePng(String name) =>
      File('${dir.path}/$name')..writeAsBytesSync(pngBytes);

  final now = DateTime.utc(2026, 9, 1, 12);

  SessionMediaItem item({
    required int sequence,
    required SessionMediaOrigin origin,
    String? path,
    bool fromAgentEnvironment = false,
    String? toolName,
    String? problem,
    DateTime? at,
  }) => SessionMediaItem(
    id: 'item-$sequence',
    origin: origin,
    sequence: sequence,
    path: path,
    fromAgentEnvironment: fromAgentEnvironment,
    toolName: toolName,
    problem: problem,
    at: at ?? now.subtract(const Duration(minutes: 3)),
  );

  Future<void> pumpList(
    WidgetTester tester,
    List<SessionMediaItem> items, {
    String? Function(String path)? resolveHostPath,
    Size size = const Size(360, 700),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionMediaList(
            items: items,
            resolveHostPath: resolveHostPath,
            now: now,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an image the agent read is shown with its file name', (
    tester,
  ) async {
    final real = writePng('shot.png');
    await pumpList(tester, [
      item(sequence: 1, origin: SessionMediaOrigin.read, path: real.path),
    ]);

    expect(find.byType(TranscriptImagePreview), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('shot.png'), findsOneWidget);
  });

  testWidgets('a pasted image is shown — the case the owner reported', (
    tester,
  ) async {
    // A paste carries bytes and no path, so the transcript's own preview had
    // nothing to draw and the owner saw nothing at all. The scan writes the
    // bytes out; by the time the list sees it, it is an ordinary file.
    final extracted = writePng('pasted-0.png');
    await pumpList(tester, [
      item(sequence: 1, origin: SessionMediaOrigin.pasted, path: extracted.path),
    ]);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Pasted image'), findsOneWidget);
    expect(find.textContaining('Pasted'), findsWidgets);
  });

  testWidgets('a screenshot a tool returned names the tool', (tester) async {
    final extracted = writePng('captured-0.png');
    await pumpList(tester, [
      item(
        sequence: 1,
        origin: SessionMediaOrigin.captured,
        path: extracted.path,
        toolName: 'mcp__karmashala__device_screenshot',
      ),
    ]);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('device_screenshot'), findsOneWidget);
  });

  testWidgets('newest first, as asked', (tester) async {
    final oldest = writePng('oldest.png');
    final newest = writePng('newest.png');
    await pumpList(tester, [
      item(sequence: 9, origin: SessionMediaOrigin.read, path: newest.path),
      item(sequence: 1, origin: SessionMediaOrigin.read, path: oldest.path),
    ]);

    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(
      labels.indexOf('newest.png'),
      lessThan(labels.indexOf('oldest.png')),
      reason: 'descending order, as asked',
    );
  });

  testWidgets('an image that is gone from disk degrades to a note', (
    tester,
  ) async {
    await pumpList(tester, [
      item(
        sequence: 1,
        origin: SessionMediaOrigin.read,
        path: '${dir.path}/never-existed.png',
      ),
    ]);

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('no longer on disk'), findsOneWidget);
    // The row still identifies what is missing — that is the whole point of
    // listing it rather than hiding it.
    expect(find.text('never-existed.png'), findsOneWidget);
  });

  testWidgets('a WSL path is translated before dart:io is asked to open it', (
    tester,
  ) async {
    // The agent writes the path in *its* environment; `Image.file` runs on the
    // Windows host. Same explicit step `EditorActions.windowsPathFor` makes.
    final real = writePng('shot.png');
    await pumpList(
      tester,
      [
        item(
          sequence: 1,
          origin: SessionMediaOrigin.read,
          path: '/mnt/c/agent/shot.png',
          fromAgentEnvironment: true,
        ),
      ],
      resolveHostPath: (path) =>
          path == '/mnt/c/agent/shot.png' ? real.path : null,
    );

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('an extracted picture is never put through the translator', (
    tester,
  ) async {
    // It was written by *this* process, into this process's cache. Handing it
    // to a WSL translator would corrupt a path that is already correct.
    final extracted = writePng('pasted-0.png');
    var asked = 0;
    await pumpList(
      tester,
      [
        item(
          sequence: 1,
          origin: SessionMediaOrigin.pasted,
          path: extracted.path,
        ),
      ],
      resolveHostPath: (path) {
        asked++;
        return null;
      },
    );

    expect(asked, 0);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('opening an item shows the full picture', (tester) async {
    final real = writePng('shot.png');
    await pumpList(tester, [
      item(sequence: 1, origin: SessionMediaOrigin.read, path: real.path),
    ]);

    // The thumbnail is the control, exactly as it is in the transcript: it is
    // left-aligned at the picture's own width, so the tile around it is not the
    // hit target.
    await tester.tap(
      find.descendant(
        of: find.byType(TranscriptImagePreview),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();

    // The transcript's viewer, reused rather than written twice.
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('a block the scan could not extract says why', (tester) async {
    await pumpList(tester, [
      item(
        sequence: 1,
        origin: SessionMediaOrigin.pasted,
        problem: 'That image is too large to preview here (48.0 MB).',
      ),
    ]);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('too large'), findsOneWidget);
  });

  testWidgets('a session with no pictures says so', (tester) async {
    await pumpList(tester, const []);

    expect(find.byType(TranscriptImagePreview), findsNothing);
    expect(find.textContaining('No images'), findsOneWidget);
    expect(find.byType(PanePlaceholder), findsOneWidget);
  });

  testWidgets('the list survives the window matrix', (tester) async {
    final real = writePng('shot.png');
    final items = [
      item(sequence: 3, origin: SessionMediaOrigin.read, path: real.path),
      item(
        sequence: 2,
        origin: SessionMediaOrigin.captured,
        path: real.path,
        toolName: 'mcp__karmashala__browser_screenshot',
      ),
      item(
        sequence: 1,
        origin: SessionMediaOrigin.pasted,
        problem: 'That image is no longer on disk.',
      ),
    ];

    await expectSurvivesWindowMatrix(
      tester,
      // The panel body is never the whole window: it is 240–620px of it, so
      // that is the box the list has to survive at every text scale.
      build: () => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 240,
              child: SessionMediaList(items: items, now: now),
            ),
          ),
        ),
      ),
      because: 'the media panel is as narrow as 240px',
    );
  });
}
