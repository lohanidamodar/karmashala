// Renders the chat's copy menu on a link, a path and a picture at desktop
// width, the picture's hover buttons, and the sheet a long-press opens on a
// 390 px phone (text ×1 and ×1.6):
//
//   flutter test tool/chat_copy_screenshot.dart
//
// Images land in build/chat-copy-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/process.dart' show EnvironmentKind, EnvironmentPath;
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
import 'package:karmashala/src/features/sessions/presentation/transcript_inline_images.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

const _outDir = 'build/chat-copy-screenshots';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final asset in assets) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }

  await load(kBundledSansFamily, [
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'packages/karmashala_ui/fonts/Geist-$weight.ttf',
  ]);
  await load(kBundledMonoFamily, [
    'packages/karmashala_ui/fonts/JetBrainsMono-Regular.ttf',
  ]);
  await load('packages/picons/PhosphorRegular', [
    'packages/picons/lib/fonts/Phosphor.ttf',
  ]);
  await load('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']);
}

/// A made-up screenshot: a gradient with a bar, so the picture reads as one.
final Uint8List _picture = () {
  final image = img.Image(width: 360, height: 220);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(x, y, 40 + x * 120 ~/ 360, 70 + y * 90 ~/ 220, 160);
    }
  }
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: 359,
    y2: 28,
    color: img.ColorRgb8(30, 30, 36),
  );
  return img.encodePng(image);
}();

class _Loader implements FilePreviewLoader {
  @override
  Future<FilePreviewData> load(EnvironmentPath path) async => FilePreviewData(
    kind: previewKindFor(path.path),
    size: _picture.length,
    bytes: _picture,
  );
}

const _folder = EnvironmentPath(
  environmentId: 'wsl:arch',
  path: '/home/me/karmashala',
);

const _messages = [
  ChatMessage(
    role: 'user',
    text: 'Where did the login screen change, and is there a screenshot?',
  ),
  ChatMessage(
    role: 'agent',
    text:
        'The flow lives in `app/lib/src/auth/login_page.dart`; the guard is '
        'in lib/src/auth/session_guard.dart:42. See the '
        '[Flutter routing docs](https://docs.flutter.dev/ui/navigation) for '
        'why the redirect moved.\n\nThe new screen is shots/login.png.',
  ),
];

void main() {
  setUpAll(() async {
    await _loadFonts();
    Directory(_outDir).createSync(recursive: true);
  });

  Future<GlobalKey> pump(
    WidgetTester tester,
    Size size, {
    bool touch = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final menu = ChatTargetMenu(
      folder: () => _folder,
      kindOf: (_) => EnvironmentKind.wsl,
      openPath: (_) async {},
      openLink: (_) async {},
      canReveal: (_) => true,
      reveal: (_) async {},
      imageClipboard: () => const ImageClipboard(),
      saveImage: (_, _) async {},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [filePreviewLoaderProvider.overrideWithValue(_Loader())],
        child: RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            builder: (context, app) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: UiDensityScope(
                density: touch ? UiDensity.touch : UiDensity.pointer,
                child: RowMenuSheetScope(
                  present: showRowMenuSheet,
                  child: app!,
                ),
              ),
            ),
            home: Scaffold(
              body: TranscriptInlineImages(
                place: (path) => placeTranscriptPath(
                  path,
                  folder: _folder,
                  kind: EnvironmentKind.wsl,
                ),
                onOpen: (_) {},
                child: ChatTargetMenuScope(
                  menu: menu,
                  child: ChatTranscriptView(
                    messages: _messages,
                    onPathTap: (_) {},
                    onLinkTap: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Pictures decode off the test clock.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    await tester.pump();
    return key;
  }

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

  Future<void> shoot(WidgetTester tester, GlobalKey key, String name) async {
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<void> rightClick(WidgetTester tester, Offset at) async {
    await tester.tapAt(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
  }

  const desktop = Size(1100, 760);

  testWidgets('menu on a link', (tester) async {
    final key = await pump(tester, desktop);
    await rightClick(tester, spanAt(tester, 'routing docs'));
    await shoot(tester, key, 'desktop-link-menu');
  });

  testWidgets('menu on a path', (tester) async {
    final key = await pump(tester, desktop);
    await rightClick(tester, spanAt(tester, 'login_page.dart'));
    await shoot(tester, key, 'desktop-path-menu');
  });

  testWidgets('menu on an image', (tester) async {
    final key = await pump(tester, desktop);
    final image = find.byKey(const ValueKey('inline-image-shots/login.png'));
    await rightClick(tester, tester.getCenter(image));
    await shoot(tester, key, 'desktop-image-menu');
  });

  testWidgets('hover on an image', (tester) async {
    final key = await pump(tester, desktop);
    final image = find.byKey(const ValueKey('inline-image-shots/login.png'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(image));
    await tester.pump();
    await shoot(tester, key, 'desktop-image-hover');
  });

  for (final scale in [1.0, 1.6]) {
    testWidgets('sheet at 390 px, text x$scale', (tester) async {
      final key = await pump(
        tester,
        const Size(390, 844),
        touch: true,
        textScale: scale,
      );
      await tester.longPressAt(spanAt(tester, 'session_guard.dart'));
      await shoot(tester, key, 'phone-390-path-sheet-x$scale');
    });
  }

  testWidgets('sheet on an image at 390 px', (tester) async {
    final key = await pump(tester, const Size(390, 844), touch: true);
    final image = find.byKey(const ValueKey('inline-image-shots/login.png'));
    await tester.ensureVisible(image);
    await tester.pumpAndSettle();
    await tester.longPressAt(tester.getCenter(image));
    await shoot(tester, key, 'phone-390-image-sheet');
  });
}
