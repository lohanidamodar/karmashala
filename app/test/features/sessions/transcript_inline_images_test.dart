import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/sessions/application/file_preview_loader.dart';
import 'package:karmashala/src/features/sessions/domain/file_preview_kind.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_activity_row.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_image_preview.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_inline_images.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';

/// The owner: "why don't we auto-preview images in chat?" A picture a message,
/// a tool row or markdown names is drawn in place, with no click and no prompt.
void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  group('paths by shape', () {
    test('pictures are found, once each, without their line', () {
      expect(
        inlineImagePaths(
          'Saved shots/home.png and /tmp/a.svg:3, then shots/home.png again; '
          'see lib/main.dart and C:\\out\\b.JPG.',
        ),
        ['shots/home.png', '/tmp/a.svg', r'C:\out\b.JPG'],
      );
    });

    test('a bare file name counts, the tail of a path does not', () {
      expect(inlineImagePaths('Saved screenshot.png, then out/logo.SVG.'), [
        'screenshot.png',
        'out/logo.SVG',
      ]);
    });

    test('a web address and an embedded picture are left alone', () {
      expect(
        inlineImagePaths(
          'From https://example.com/img/a.png: ![home](shots/home.png)',
        ),
        isEmpty,
      );
    });

    test('every kind the owner named', () {
      for (final ext in ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp']) {
        expect(inlineImagePaths('out/x.$ext'), ['out/x.$ext'], reason: ext);
      }
    });
  });

  group('drawn in the conversation', () {
    late _Loader loader;
    late List<String> opened;

    setUp(() {
      loader = _Loader(png);
      opened = [];
    });

    Future<void> pumpChat(
      WidgetTester tester,
      List<ChatMessage> messages, {
      double width = 1200,
      double textScale = 1,
      bool scoped = true,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      final chat = ChatTranscriptView(messages: messages);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [filePreviewLoaderProvider.overrideWithValue(loader)],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: TextScaler.linear(textScale),
              ),
              child: Scaffold(
                body: scoped
                    ? TranscriptInlineImages(
                        place: (path) => EnvironmentPath(
                          environmentId: 'wsl:arch',
                          path: path.startsWith('/') ? path : '/repo/$path',
                        ),
                        onOpen: opened.add,
                        child: chat,
                      )
                    : chat,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a path in an agent message is drawn, with no prompt', (
      tester,
    ) async {
      await pumpChat(tester, const [
        ChatMessage(role: 'agent', text: 'The screen is in shots/home.png.'),
      ]);
      expect(
        find.byKey(const ValueKey('inline-image-shots/home.png')),
        findsOne,
      );
      expect(loader.asked, [
        const EnvironmentPath(
          environmentId: 'wsl:arch',
          path: '/repo/shots/home.png',
        ),
      ]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Preview anyway'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Copy path'), findsOneWidget);
    });

    testWidgets('a tool row that names a picture draws it', (tester) async {
      await pumpChat(tester, const [
        ChatMessage(
          role: 'tool',
          text: '',
          tool: ToolActivity(
            name: 'Bash',
            subject: 'flutter screenshot -o build/shot.png',
            output: 'Screenshot written to build/shot.png',
          ),
        ),
      ]);
      expect(
        find.byKey(const ValueKey('inline-image-build/shot.png')),
        findsOne,
      );
      expect(loader.asked, hasLength(1));
    });

    testWidgets('a picture a tool answered with is not hidden by the fold', (
      tester,
    ) async {
      await pumpChat(tester, const [
        ChatMessage(
          role: 'tool',
          text: '',
          tool: ToolActivity(
            name: 'mcp__karmashala__browser_screenshot',
            output: 'Captured.',
            imagePath: '/data/tool-images/abc.png',
          ),
        ),
      ]);
      expect(find.byType(TranscriptImagePreview), findsOneWidget);
    });

    testWidgets('an opened tool card draws what it names', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [filePreviewLoaderProvider.overrideWithValue(loader)],
          child: MaterialApp(
            home: Scaffold(
              body: TranscriptInlineImages(
                place: (path) =>
                    EnvironmentPath(environmentId: 'ssh:box', path: path),
                child: const ToolActivityBody(
                  activity: ToolActivity(
                    name: 'Write',
                    subject: '/srv/app/diagram.svg',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('inline-image-/srv/app/diagram.svg')),
        findsOne,
      );
      expect(loader.asked.single.environmentId, 'ssh:box');
    });

    testWidgets('markdown draws a local picture where it stands, once', (
      tester,
    ) async {
      await pumpChat(tester, const [
        ChatMessage(role: 'agent', text: 'Here:\n\n![home](shots/home.png)'),
      ]);
      expect(
        find.byKey(const ValueKey('inline-image-shots/home.png')),
        findsOne,
      );
      expect(loader.asked, hasLength(1));
    });

    testWidgets('a web picture waits for a tap, as it did', (tester) async {
      await pumpChat(tester, const [
        ChatMessage(role: 'agent', text: '![a](https://example.com/a.png)'),
      ]);
      expect(find.text('Load image from example.com'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(loader.asked, isEmpty);
    });

    testWidgets('several pictures make a strip, read as they come into view', (
      tester,
    ) async {
      final names = [for (var i = 0; i < 20; i++) 'shots/s$i.png'];
      await pumpChat(tester, [
        ChatMessage(role: 'agent', text: 'Saved ${names.join(', ')}.'),
      ], width: 500);
      expect(find.byKey(const ValueKey('inline-image-strip')), findsOne);
      final first = loader.asked.length;
      expect(first, greaterThan(1));
      expect(first, lessThan(names.length), reason: 'off-screen ones wait');

      await tester.drag(
        find.byKey(const ValueKey('inline-image-strip')),
        const Offset(-1500, 0),
      );
      await tester.pump();
      await tester.pump();
      expect(loader.asked.length, greaterThan(first));
    });

    testWidgets('past the most a row draws, the rest are counted', (
      tester,
    ) async {
      final names = [
        for (var i = 0; i < kInlineImageStripMax + 6; i++) 'shots/s$i.png',
      ];
      await pumpChat(tester, [
        ChatMessage(role: 'agent', text: names.join(' ')),
      ]);
      expect(find.text('and 6 more'), findsOneWidget);
    });

    testWidgets('a tap enlarges it, with Open and Copy path', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpChat(tester, const [
        ChatMessage(role: 'agent', text: 'See a.png and b.png.'),
      ]);
      await tester.tap(find.byKey(const ValueKey('inline-image-b.png')));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('/repo/b.png'), findsOneWidget);

      await tester.tap(find.text('Copy path'));
      await tester.pump();
      expect(copied, '/repo/b.png');

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(opened, ['b.png']);
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('a picture past the media cap says so and is not drawn', (
      tester,
    ) async {
      loader.data = const FilePreviewData(
        kind: FilePreviewKind.image,
        size: kPreviewMediaBytes + 1024 * 1024,
        tooLarge: true,
      );
      await pumpChat(tester, const [
        ChatMessage(role: 'agent', text: 'Big one: huge.png'),
      ]);
      expect(find.textContaining('Too large to preview (17.0 MB)'), findsOne);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('with no scope above, nothing is read', (tester) async {
      await pumpChat(tester, const [
        ChatMessage(role: 'agent', text: 'The screen is in shots/home.png.'),
      ], scoped: false);
      expect(loader.asked, isEmpty);
    });

    for (final width in const [360.0, 1440.0]) {
      testWidgets('no overflow at $width px, text ×1.6', (tester) async {
        await pumpChat(
          tester,
          [
            const ChatMessage(
              role: 'agent',
              text: 'One: a-rather-long-folder-name/deeper/screenshot-home.png',
            ),
            ChatMessage(
              role: 'agent',
              text: [for (var i = 0; i < 8; i++) 'shots/s$i.png'].join(' '),
            ),
          ],
          width: width,
          textScale: 1.6,
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('inline-image-strip')), findsOne);
      });
    }
  });

  group('through the server', () {
    for (final environment in const ['wsl:archlinux', 'ssh:box']) {
      testWidgets('a picture in $environment is read by the files API', (
        tester,
      ) async {
        final box = Directory.systemTemp.createTempSync('ks-inline-');
        addTearDown(() => removeTempDirectory(box));
        File(p.join(box.path, 'home', 'me', 'app', 'shots', 'shot.png'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(png);
        final server = FakeDataServer()
          ..filesWork.posixAt(environment, box.path);
        final client = await server.connect();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 900);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [dataClientProvider.overrideWithValue(client)],
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: Scaffold(
                body: TranscriptInlineImages(
                  place: (path) => EnvironmentPath(
                    environmentId: environment,
                    path: p.posix.join('/home/me/app', path),
                  ),
                  child: ChatTranscriptView(
                    messages: const [
                      ChatMessage(
                        role: 'agent',
                        text: 'Look at shots/shot.png',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 30 && find.byType(Image).evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.byType(Image), findsOneWidget);
        expect(find.textContaining('Could not'), findsNothing);
      });
    }
  });
}

class _Loader implements FilePreviewLoader {
  _Loader(this.bytes);

  final List<int> bytes;
  final List<EnvironmentPath> asked = [];
  FilePreviewData? data;

  @override
  Future<FilePreviewData> load(EnvironmentPath path) async {
    asked.add(path);
    return data ??
        FilePreviewData(
          kind: previewKindFor(path.path),
          size: bytes.length,
          bytes: Uint8List.fromList(bytes),
        );
  }
}
