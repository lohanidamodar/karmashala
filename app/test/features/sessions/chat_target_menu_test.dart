import 'package:agent_cli/process.dart' show EnvironmentKind, EnvironmentPath;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:karmashala/src/app/widgets/row_menu_sheet.dart';
import 'package:karmashala/src/features/editor/presentation/media/media_clipboard.dart';
import 'package:karmashala/src/features/sessions/application/file_preview_loader.dart';
import 'package:karmashala/src/features/sessions/domain/file_preview_kind.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_target_menu.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_activity_row.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_inline_images.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart' show TranscriptPathLink;

/// The owner, 2026-10-08: "in chat, an easy option to copy image, copy link,
/// copy paths etc." One menu for every linkable thing in the conversation.
void main() {
  // Big enough to have a size in the enlarged view.
  final png = img.encodePng(img.Image(width: 40, height: 40));

  group('a path placed in the session', () {
    test('Windows resolves against the folder, backslashes and all', () {
      const folder = EnvironmentPath(
        environmentId: 'local',
        path: r'C:\src\repo',
      );
      final full = placeTranscriptPath(
        r'lib\main.dart:12',
        folder: folder,
        kind: EnvironmentKind.windowsNative,
      );
      expect(full.path, r'C:\src\repo\lib\main.dart');
      expect(
        relativeTranscriptPath(
          full,
          folder: folder,
          kind: EnvironmentKind.windowsNative,
        ),
        r'lib\main.dart',
      );
    });

    test('WSL and SSH are POSIX, whatever this machine is', () {
      for (final kind in [EnvironmentKind.wsl, EnvironmentKind.ssh]) {
        const folder = EnvironmentPath(
          environmentId: 'remote',
          path: '/home/me/repo',
        );
        final full = placeTranscriptPath(
          'lib/a.dart:3',
          folder: folder,
          kind: kind,
        );
        expect(full.path, '/home/me/repo/lib/a.dart', reason: '$kind');
        expect(full.environmentId, 'remote');
        expect(
          relativeTranscriptPath(full, folder: folder, kind: kind),
          'lib/a.dart',
        );
        final outside = placeTranscriptPath(
          '/etc/hosts',
          folder: folder,
          kind: kind,
        );
        expect(outside.path, '/etc/hosts');
        expect(
          relativeTranscriptPath(outside, folder: folder, kind: kind),
          '../../../etc/hosts',
        );
      }
    });
  });

  group('the menu', () {
    late List<String> copied;
    late List<String> openedPaths;
    late List<String> openedLinks;
    late List<EnvironmentPath> revealed;
    late List<String> saved;
    late _FakeImageClipboard clipboard;
    late List<String> haptics;
    late EnvironmentPath folder;
    late EnvironmentKind kind;

    setUp(() {
      copied = [];
      openedPaths = [];
      openedLinks = [];
      revealed = [];
      saved = [];
      haptics = [];
      clipboard = _FakeImageClipboard();
      folder = const EnvironmentPath(
        environmentId: 'wsl:arch',
        path: '/home/me/repo',
      );
      kind = EnvironmentKind.wsl;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add(call.arguments as String);
            }
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    ChatTargetMenu menu() => ChatTargetMenu(
      folder: () => folder,
      kindOf: (_) => kind,
      openPath: (token) async => openedPaths.add(token),
      openLink: (href) async => openedLinks.add(href),
      canReveal: (_) => true,
      reveal: (path) async => revealed.add(path),
      imageClipboard: () => clipboard,
      saveImage: (_, name) async => saved.add(name),
    );

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      bool touch = false,
      double width = 1200,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      final chatMenu = menu();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            filePreviewLoaderProvider.overrideWithValue(_Loader(png)),
            imageClipboardProvider.overrideWithValue(clipboard),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, app) => UiDensityScope(
              density: touch ? UiDensity.touch : UiDensity.pointer,
              child: RowMenuSheetScope(present: showRowMenuSheet, child: app!),
            ),
            home: Scaffold(
              body: TranscriptInlineImages(
                place: (path) =>
                    placeTranscriptPath(path, folder: folder, kind: kind),
                onOpen: openedPaths.add,
                child: ChatTargetMenuScope(menu: chatMenu, child: child),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Widget chat(String text) => ChatTranscriptView(
      messages: [ChatMessage(role: 'agent', text: text)],
      onPathTap: (_) {},
      onLinkTap: (_) {},
    );

    /// The middle of [needle] where a paragraph draws it.
    Offset spanAt(WidgetTester tester, String needle) {
      final paragraph = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .firstWhere((p) => p.text.toPlainText().contains(needle));
      final at = paragraph.text.toPlainText().indexOf(needle);
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: at, extentOffset: at + needle.length),
          )
          .first;
      return paragraph.localToGlobal(box.toRect().center);
    }

    Future<void> rightClick(WidgetTester tester, Offset at) async {
      await tester.tapAt(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
    }

    /// The menu's [label], not a button of the same name beside the picture.
    Future<void> pick(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is DesktopMenuItem<String>),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<String> menuLabels(WidgetTester tester) => [
      for (final item in tester.widgetList<DesktopMenuItem<String>>(
        find.byWidgetPredicate((w) => w is DesktopMenuItem<String>),
      ))
        item.label,
    ];

    testWidgets('a web link: open, copy it, copy its text, and says so', (
      tester,
    ) async {
      await pump(tester, chat('See [the docs](https://example.com/d) now.'));
      await rightClick(tester, spanAt(tester, 'the docs'));

      expect(menuLabels(tester), ['Open link', 'Copy link', 'Copy link text']);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, ['https://example.com/d']);
      expect(find.text('Link copied to clipboard'), findsOne);

      await rightClick(tester, spanAt(tester, 'the docs'));
      await tester.tap(find.text('Open link'));
      await tester.pumpAndSettle();
      expect(openedLinks, ['https://example.com/d']);
    });

    testWidgets('a link whose text is its address offers no Copy link text', (
      tester,
    ) async {
      await pump(
        tester,
        chat('Go to [https://example.com/x](https://example.com/x) first.'),
      );
      await rightClick(tester, spanAt(tester, 'example.com'));
      expect(menuLabels(tester), ['Open link', 'Copy link']);
    });

    const pathItems = [
      'Open',
      'Reveal in folder',
      'Copy path as written',
      'Copy full path',
      'Copy relative path',
    ];

    testWidgets('a bare path: each copy, resolved against the folder', (
      tester,
    ) async {
      await pump(tester, chat('Look at lib/main.dart:12 here.'));
      final at = spanAt(tester, 'lib/main.dart');

      await rightClick(tester, at);
      expect(menuLabels(tester), pathItems);
      await tester.tap(find.text('Copy path as written'));
      await tester.pumpAndSettle();
      await rightClick(tester, at);
      await tester.tap(find.text('Copy full path'));
      await tester.pumpAndSettle();
      await rightClick(tester, at);
      await tester.tap(find.text('Copy relative path'));
      await tester.pumpAndSettle();
      await rightClick(tester, at);
      await tester.tap(find.text('Reveal in folder'));
      await tester.pumpAndSettle();
      await rightClick(tester, at);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(copied, [
        'lib/main.dart:12',
        '/home/me/repo/lib/main.dart',
        'lib/main.dart',
      ]);
      expect(revealed.single.path, '/home/me/repo/lib/main.dart');
      expect(openedPaths, ['lib/main.dart:12']);
    });

    testWidgets('a backticked path in a Windows session', (tester) async {
      folder = const EnvironmentPath(
        environmentId: 'local',
        path: r'C:\src\repo',
      );
      kind = EnvironmentKind.windowsNative;
      await pump(tester, chat(r'Edit `lib\auth.dart` next.'));
      final at = spanAt(tester, r'lib\auth.dart');

      await rightClick(tester, at);
      expect(menuLabels(tester), pathItems);
      await tester.tap(find.text('Copy full path'));
      await tester.pumpAndSettle();
      expect(copied, [r'C:\src\repo\lib\auth.dart']);
      expect(find.text('Full path copied to clipboard'), findsOne);
    });

    testWidgets('an SSH session has no Reveal in folder', (tester) async {
      folder = const EnvironmentPath(environmentId: 'ssh:box', path: '/srv');
      kind = EnvironmentKind.ssh;
      final chatMenu = ChatTargetMenu(
        folder: () => folder,
        kindOf: (_) => kind,
        openPath: (_) async {},
        openLink: (_) async {},
        canReveal: (_) => false,
        reveal: (_) async {},
        imageClipboard: () => clipboard,
      );
      final labels = [
        for (final item in chatMenu.itemsFor(
          const TranscriptPathLink('app/x.py'),
        ))
          if (item is DesktopMenuItem<String>) item.label,
      ];
      expect(labels, [
        'Open',
        'Copy path as written',
        'Copy full path',
        'Copy relative path',
      ]);
    });

    testWidgets('a path in a tool row', (tester) async {
      await pump(
        tester,
        ToolActivityBody(
          activity: const ToolActivity(
            name: 'Bash',
            subject: 'dart test test/auth_test.dart',
          ),
          onPathTap: (_) {},
        ),
      );
      await rightClick(tester, spanAt(tester, 'test/auth_test.dart'));
      expect(menuLabels(tester), pathItems);
      await tester.tap(find.text('Copy full path'));
      await tester.pumpAndSettle();
      expect(copied, ['/home/me/repo/test/auth_test.dart']);
    });

    testWidgets('inline code copies as written', (tester) async {
      await pump(tester, chat('Run `flutter test --tags x` again.'));
      await rightClick(tester, spanAt(tester, 'flutter test'));
      expect(menuLabels(tester), ['Copy']);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, ['flutter test --tags x']);
      expect(find.text('Code copied to clipboard'), findsOne);
    });

    testWidgets('plain prose keeps the selection menu', (tester) async {
      await pump(tester, chat('Nothing to link in this sentence.'));
      await rightClick(tester, spanAt(tester, 'Nothing'));
      expect(menuLabels(tester), isEmpty);
    });

    testWidgets('an image: copy its bytes, its path, save it, open it', (
      tester,
    ) async {
      await pump(tester, chat('The screen is in shots/home.png.'));
      final image = find.byKey(const ValueKey('inline-image-shots/home.png'));
      expect(image, findsOne);

      await rightClick(tester, tester.getCenter(image));
      expect(menuLabels(tester), [
        'Copy image',
        'Copy path',
        'Save as…',
        'Open',
      ]);
      await pick(tester, 'Copy image');
      await tester.pumpAndSettle();
      expect(clipboard.writes.single, png);
      expect(find.text('Image copied to clipboard'), findsOne);

      await rightClick(tester, tester.getCenter(image));
      await pick(tester, 'Save as…');
      await tester.pumpAndSettle();
      expect(saved, ['home.png']);
    });

    testWidgets('hovering an image shows Copy and Open on it', (tester) async {
      await pump(tester, chat('The screen is in shots/home.png.'));
      final image = find.byKey(const ValueKey('inline-image-shots/home.png'));
      expect(find.byKey(const ValueKey('image-hover-copy')), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(image));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('image-hover-copy')));
      await tester.pumpAndSettle();
      expect(clipboard.writes.single, png);

      await mouse.moveTo(tester.getCenter(image));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('image-hover-open')));
      await tester.pumpAndSettle();
      expect(openedPaths, ['shots/home.png']);
    });

    testWidgets('the enlarged image still copies through the chat', (
      tester,
    ) async {
      await pump(tester, chat('The screen is in shots/home.png.'));
      await tester.tap(
        find.byKey(const ValueKey('inline-image-shots/home.png')),
      );
      await tester.pumpAndSettle();
      // The viewer's route is outside the chat; its Copy image still runs.
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byKey(const ValueKey('inline-image-copy-image')),
        ),
      );
      await tester.pumpAndSettle();
      expect(clipboard.writes.single, png);
      expect(find.text('Image copied to clipboard'), findsOne);
    });

    testWidgets('long-press on touch opens a sheet, with a light haptic', (
      tester,
    ) async {
      await pump(
        tester,
        chat('Look at lib/main.dart:12 here.'),
        touch: true,
        width: 390,
      );
      await tester.longPressAt(spanAt(tester, 'lib/main.dart'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOne);
      expect(find.text('Copy relative path'), findsOne);
      expect(find.text('Save as…'), findsNothing);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await tester.tap(find.text('Copy path as written'));
      await tester.pumpAndSettle();
      expect(copied, ['lib/main.dart:12']);
    });

    testWidgets('a selection survives a right-click on a link in it', (
      tester,
    ) async {
      await pump(tester, chat('Before lib/main.dart after the path.'));
      final gesture = await tester.startGesture(
        spanAt(tester, 'Before'),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(spanAt(tester, 'path.'));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      await rightClick(tester, spanAt(tester, 'lib/main.dart'));
      expect(menuLabels(tester).first, 'Copy selection');
      expect(menuLabels(tester), containsAll(pathItems));
      await tester.tap(find.text('Copy selection'));
      await tester.pumpAndSettle();
      expect(copied.single, contains('lib/main.dart after the'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Ctrl+C on a focused image copies it', (tester) async {
      await pump(tester, chat('The screen is in shots/home.png.'));
      final tile = find.byKey(const ValueKey('inline-image-shots/home.png'));
      Focus.of(
        tester.element(
          find.descendant(of: tile, matching: find.byType(DecoratedBox)).first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();
      expect(clipboard.writes.single, png);
    });

    testWidgets('a message copies as plain text', (tester) async {
      await pump(tester, chat('A **bold** move:\n\n- one\n- `two`'));
      final row = find.textContaining('bold', findRichText: true).first;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(row));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('chat-copy-plain')));
      await tester.pump();
      expect(copied, ['A bold move:\n\n- one\n- two']);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

class _FakeImageClipboard extends ImageClipboard {
  final writes = <Uint8List>[];

  @override
  bool get supported => true;

  @override
  Future<void> writePng(Uint8List png) async => writes.add(png);
}

class _Loader implements FilePreviewLoader {
  _Loader(this.bytes);

  final List<int> bytes;

  @override
  Future<FilePreviewData> load(EnvironmentPath path) async => FilePreviewData(
    kind: previewKindFor(path.path),
    size: bytes.length,
    bytes: Uint8List.fromList(bytes),
  );
}
