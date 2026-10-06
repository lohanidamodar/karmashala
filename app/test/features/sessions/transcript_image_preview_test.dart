import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_activity_row.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_image_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/temp_directory.dart';
import '../../support/tool_runs.dart';

/// The owner's first ask: "when the agent reads an image the transcript shows
/// only a file name" — Claude Code records the read as
/// `tool_use{name:'Read', input:{file_path:'…/shot.png'}}`, so the path is
/// there and the picture never was.
///
/// Every degraded case here is one the real store produces: a screenshot the
/// agent deleted after looking at it, a WSL path that `dart:io` on Windows
/// cannot open until it is translated, a file too big to hand a decoder, and
/// an ordinary source file that is not an image at all. None of them may take
/// the transcript down with them.
void main() {
  late Directory dir;

  /// A real 1x1 PNG — `Image.file` is given an actual decodable file, not a
  /// mock, so the degraded paths are the only ones that are simulated.
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  setUp(() => dir = Directory.systemTemp.createTempSync('transcript_image'));
  tearDown(() => removeTempDirectory(dir));

  File writePng(String name) =>
      File('${dir.path}/$name')..writeAsBytesSync(pngBytes);

  Future<void> pumpPreview(
    WidgetTester tester,
    String path, {
    String? Function(String path)? resolveHostPath,
    int maxBytes = kMaxImagePreviewBytes,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TranscriptImagePreview(
          path: path,
          resolveHostPath: resolveHostPath,
          maxBytes: maxBytes,
        ),
      ),
    ),
  );

  testWidgets('an image the agent read is previewed, not just named', (
    tester,
  ) async {
    await pumpPreview(tester, writePng('shot.png').path);

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('the preview opens a viewer when it is activated', (
    tester,
  ) async {
    await pumpPreview(tester, writePng('shot.png').path);

    // Tappable before the decoder has finished: the thumbnail reserves its
    // frame, so it is a target from the first frame rather than a 0x0 box.
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('an image that is gone from disk degrades to a note', (
    tester,
  ) async {
    await pumpPreview(tester, '${dir.path}/never-existed.png');

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('no longer on disk'), findsOneWidget);
  });

  testWidgets('an image too large to decode is refused, not attempted', (
    tester,
  ) async {
    await pumpPreview(tester, writePng('huge.png').path, maxBytes: 4);

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('too large'), findsOneWidget);
  });

  testWidgets('a cached tool image that was swept says it is no longer kept', (
    tester,
  ) async {
    await pumpPreview(
      tester,
      '${dir.path}/tool-images/cbf29ce484222325-12.png',
    );

    expect(find.byType(Image), findsNothing);
    expect(find.text('That image is no longer kept.'), findsOneWidget);
  });

  testWidgets('a WSL path is translated before dart:io is asked to open it', (
    tester,
  ) async {
    // The agent writes the path in *its* environment. `Image.file` runs on the
    // Windows host, so the row translates first — the same explicit step
    // `EditorActions.windowsPathFor` makes everywhere else.
    final real = writePng('shot.png');
    await pumpPreview(
      tester,
      '/mnt/c/agent/shot.png',
      resolveHostPath: (p) => p == '/mnt/c/agent/shot.png' ? real.path : null,
    );

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('an untranslated WSL path degrades instead of throwing', (
    tester,
  ) async {
    await pumpPreview(tester, '/mnt/c/agent/nothing-here.png');

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('no longer on disk'), findsOneWidget);
  });

  testWidgets('a tool row for an image read shows the path and the picture', (
    tester,
  ) async {
    final real = writePng('shot.png');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscriptView(
            messages: [
              ChatMessage(
                role: 'tool',
                text: 'Read(${real.path})',
                tool: ToolActivity(
                  name: 'Read',
                  subject: real.path,
                  imagePath: real.path,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // A finished call is folded under its turn's line: open it to its card.
    await openToolRuns(tester);

    expect(find.byType(TranscriptImagePreview), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ToolActivityBody),
        matching: find.text(real.path),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a tool row for an ordinary file previews nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscriptView(
            messages: const [
              ChatMessage(
                role: 'tool',
                text: 'Read(lib/main.dart)',
                tool: ToolActivity(name: 'Read', subject: 'lib/main.dart'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await openToolRuns(tester);

    expect(find.byType(TranscriptImagePreview), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ToolActivityBody),
        matching: find.text('lib/main.dart'),
      ),
      findsOneWidget,
    );
  });
}
