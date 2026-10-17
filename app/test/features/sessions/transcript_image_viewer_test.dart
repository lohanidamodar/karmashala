import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/file_preview_loader.dart';
import 'package:karmashala/src/features/sessions/application/transcript_image_reads.dart';
import 'package:karmashala/src/features/sessions/domain/file_preview_kind.dart';
import 'package:karmashala/src/features/sessions/domain/image_dimensions.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_image_card.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_image_viewer.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_inline_images.dart';
import 'package:karmashala/src/features/editor/presentation/media/image_viewer.dart';
import 'package:karmashala_ui/primitives.dart' show InlineSpinner;
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/image_reads.dart';

/// Round 108: one card for every picture in the chat (the owner's card A) and
/// one viewer for all of them (V1, a lightbox with a filmstrip).
void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  /// A PNG header claiming [width] × [height]: enough for the card's sizing.
  Uint8List pngHeader(int width, int height) {
    final bytes = Uint8List(33)..setAll(0, png.sublist(0, 16));
    ByteData.sublistView(bytes)
      ..setUint32(16, width)
      ..setUint32(20, height);
    return bytes;
  }

  group('the size a header declares', () {
    test('PNG, GIF, BMP, JPEG and WebP', () {
      expect(imageDimensions(pngHeader(1080, 1754)), (
        width: 1080,
        height: 1754,
      ));
      expect(
        imageDimensions(
          Uint8List.fromList([...ascii.encode('GIF89a'), 0x40, 0x01, 0xf0, 0]),
        ),
        (width: 320, height: 240),
      );
      final bmp = Uint8List(26)..setAll(0, ascii.encode('BM'));
      ByteData.sublistView(bmp)
        ..setInt32(18, 64, Endian.little)
        ..setInt32(22, -32, Endian.little);
      expect(imageDimensions(bmp), (width: 64, height: 32));
      final jpeg = Uint8List.fromList([
        0xff, 0xd8, // start of image
        0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, // an APP0 segment
        0xff, 0xc0, 0x00, 0x11, 0x08, 0x03, 0x20, 0x05, 0x00, 0x03, //
        0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(imageDimensions(jpeg), (width: 1280, height: 800));
      final webp = Uint8List(30)
        ..setAll(0, ascii.encode('RIFF'))
        ..setAll(8, ascii.encode('WEBPVP8X'));
      webp
        ..[24] = 99
        ..[27] = 49;
      expect(imageDimensions(webp), (width: 100, height: 50));
    });

    test('anything else is not guessed at', () {
      expect(imageDimensions(Uint8List.fromList(utf8.encode('<svg/>'))), null);
      expect(imageDimensions(png.sublist(0, 10)), null);
    });
  });

  group('the card', () {
    late _Loader loader;

    setUp(() => loader = _Loader({}));

    Future<void> pumpStrip(
      WidgetTester tester,
      List<String> paths, {
      double width = 1200,
      double textScale = 1,
      bool touch = false,
      EnvironmentPath? Function(String)? place,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      Widget body = TranscriptInlineImages(
        place:
            place ??
            (path) => EnvironmentPath(environmentId: 'wsl:arch', path: path),
        onOpen: (_) {},
        child: ListView(children: [TranscriptImageStrip(paths: paths)]),
      );
      if (touch) {
        body = UiDensityScope(density: UiDensity.touch, child: body);
      }
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
              child: Scaffold(body: body),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('reading, it is a frame of the card\'s size with a spinner', (
      tester,
    ) async {
      loader.hold = Completer<FilePreviewData>();
      await pumpStrip(tester, ['/a/shot.png']);
      final frame = find.byKey(const ValueKey('inline-image-/a/shot.png'));
      expect(frame, findsOne);
      expect(tester.getSize(frame).height, Chrome.inlineImage);
      expect(find.byType(InlineSpinner), findsOne);
      loader.hold!.complete(
        FilePreviewData(
          kind: FilePreviewKind.image,
          size: png.length,
          bytes: Uint8List.fromList(png),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOne);
    });

    testWidgets('a tall portrait shot still gets a card, not a sliver', (
      tester,
    ) async {
      loader.bytes['/a/tall.png'] = pngHeader(1080, 1754);
      await pumpStrip(tester, ['/a/tall.png']);
      final card = find.byType(TranscriptImageCard);
      // 1080 × 1754 at 220 tall is 135 wide; the card keeps its minimum.
      expect(
        tester.getSize(find.byKey(const ValueKey('inline-image-/a/tall.png'))),
        const Size(Chrome.imageCardMinWidth, Chrome.inlineImage),
      );
      expect(
        find.descendant(of: card, matching: find.text('1080 × 1754 · 33 B')),
        findsOne,
      );
    });

    testWidgets('gone, it is a dashed row naming the file', (tester) async {
      loader.missing.add('/a/old-trail.png');
      await pumpStrip(tester, ['/a/old-trail.png']);
      expect(find.byType(TranscriptImageNote), findsOne);
      expect(
        find.text('old-trail.png is no longer on disk', findRichText: true),
        findsOne,
      );
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('with nowhere to place it, the row says so', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [filePreviewLoaderProvider.overrideWithValue(loader)],
          child: MaterialApp(
            home: Scaffold(
              body: TranscriptInlineImages(
                place: (_) => null,
                child: const TranscriptImageStrip(paths: ['shot.png']),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('no record of where this session runs'),
        findsOne,
      );
      expect(loader.asked, isEmpty);
    });

    testWidgets('a server that cannot reach it says it could not be read', (
      tester,
    ) async {
      loader.fail = true;
      await pumpStrip(tester, ['/a/shot.png']);
      expect(find.textContaining('could not be read'), findsOne);
    });

    testWidgets('an SVG is drawn, with its size', (tester) async {
      loader.bytes['/a/logo.svg'] = Uint8List.fromList(
        utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>',
        ),
      );
      await pumpStrip(tester, ['/a/logo.svg']);
      expect(find.byKey(const ValueKey('inline-image-/a/logo.svg')), findsOne);
      expect(find.textContaining('B'), findsWidgets);
    });

    testWidgets('a rebuild does not read again', (tester) async {
      // The transcript rebuilds on every poll; the read is made once.
      EnvironmentPath? place(String path) =>
          EnvironmentPath(environmentId: 'wsl:arch', path: path);
      await pumpStrip(tester, ['/a/shot.png'], place: place);
      await pumpStrip(tester, ['/a/shot.png'], place: place);
      expect(loader.asked, hasLength(1));
    });

    testWidgets('Copy path is behind ⋯, and copies the placed path', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
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
      await pumpStrip(
        tester,
        ['shot.png'],
        place: (path) =>
            EnvironmentPath(environmentId: 'wsl:arch', path: '/repo/$path'),
      );
      await tester.tap(find.byKey(const ValueKey('inline-image-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inline-image-copy')));
      await tester.pumpAndSettle();
      expect(copied, ['/repo/shot.png']);
    });

    testWidgets('its actions meet the touch target on a phone', (tester) async {
      await pumpStrip(tester, ['/a/shot.png'], width: 390, touch: true);
      for (final key in ['inline-image-open', 'inline-image-more']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(Touch.target), reason: key);
        expect(size.height, greaterThanOrEqualTo(Touch.target), reason: key);
      }
    });

    for (final width in const [360.0, 1440.0]) {
      testWidgets('no overflow at $width px, text ×1.6', (tester) async {
        loader.bytes['/a/a-very-long-file-name-for-a-screenshot-home.png'] =
            pngHeader(4000, 600);
        loader.missing.add('/a/another-long-name-that-is-gone-now.png');
        await pumpStrip(
          tester,
          ['/a/a-very-long-file-name-for-a-screenshot-home.png'],
          width: width,
          textScale: 1.6,
        );
        expect(tester.takeException(), isNull);
        await pumpStrip(
          tester,
          ['/a/another-long-name-that-is-gone-now.png'],
          width: width,
          textScale: 1.6,
        );
        expect(tester.takeException(), isNull);
        await pumpStrip(
          tester,
          [for (var i = 0; i < 6; i++) '/a/s$i.png'],
          width: width,
          textScale: 1.6,
          touch: width < 600,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the viewer', () {
    List<TranscriptImageView> images(int count, {List<String>? opened}) => [
      for (var i = 0; i < count; i++)
        TranscriptImageView(
          path: '/a/shot-$i.png',
          copyPath: '/a/shot-$i.png',
          read: () => Future.value(
            TranscriptImageRead.loaded(
              Uint8List.fromList(png),
              size: png.length,
            ),
          ),
          onOpen: opened == null ? null : () => opened.add('$i'),
        ),
    ];

    Future<void> pumpViewer(
      WidgetTester tester,
      List<TranscriptImageView> shown, {
      int initial = 0,
      double width = 1440,
      double height = 900,
      double textScale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, height);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, height),
                textScaler: TextScaler.linear(textScale),
              ),
              child: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showTranscriptImageViewer(
                      context,
                      images: shown,
                      initial: initial,
                    ),
                    child: const Text('view'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('view'));
      await tester.pumpAndSettle();
      await settleImageReads(tester);
    }

    String name(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('image-viewer-name')))
        .data!;

    String zoom(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('image-viewer-zoom')))
        .data!;

    testWidgets('previous, next, the filmstrip and the arrow keys', (
      tester,
    ) async {
      await pumpViewer(tester, images(3), initial: 1);
      expect(name(tester), 'shot-1.png');
      expect(find.text('2 of 3'), findsOne);
      expect(find.byKey(const ValueKey('image-viewer-filmstrip')), findsOne);

      await tester.tap(find.byKey(const ValueKey('image-viewer-next')));
      await tester.pumpAndSettle();
      expect(name(tester), 'shot-2.png');
      expect(find.text('3 of 3'), findsOne);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(name(tester), 'shot-0.png');

      await tester.tap(find.byKey(const ValueKey('image-viewer-thumb-2')));
      await tester.pumpAndSettle();
      expect(name(tester), 'shot-2.png');
      expect(
        find.bySemanticsLabel(RegExp('Image 3 of 3')),
        findsOne,
        reason: 'the filmstrip says which is which',
      );
    });

    testWidgets('+, - and 0 zoom; Esc closes', (tester) async {
      await pumpViewer(tester, images(1));
      final placed = zoom(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.equal);
      await tester.pumpAndSettle();
      final zoomedIn = zoom(tester);
      expect(zoomedIn, isNot(placed));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.minus, character: '-');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.minus);
      await tester.pumpAndSettle();
      expect(zoom(tester), placed);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit0, character: '0');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit0);
      await tester.pumpAndSettle();
      // A 1 px picture fitted to the stage is as far in as the viewer goes.
      expect(zoom(tester), '${(ImageViewer.maxScale * 100).round()}%');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptImageViewer), findsNothing);
    });

    testWidgets('Open closes the viewer, then opens it', (tester) async {
      final opened = <String>[];
      await pumpViewer(tester, images(2, opened: opened), initial: 1);
      await tester.tap(find.byKey(const ValueKey('image-viewer-open')));
      await tester.pumpAndSettle();
      expect(opened, ['1']);
      expect(find.byType(TranscriptImageViewer), findsNothing);
    });

    testWidgets('a phone gets the whole screen, a ⋯ menu and swipes', (
      tester,
    ) async {
      await pumpViewer(tester, images(3), width: 390, height: 844);
      expect(find.byType(Dialog), findsOne);
      expect(tester.getSize(find.byType(TranscriptImageViewer)).width, 390);
      expect(
        find.byKey(const ValueKey('image-viewer-filmstrip')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('image-viewer-copy')), findsNothing);
      expect(find.textContaining('1 of 3'), findsOne);

      await tester.tap(find.byKey(const ValueKey('image-viewer-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-viewer-menu-copy')), findsOne);
      await tester.tapAt(const Offset(10, 400));
      await tester.pumpAndSettle();

      await tester.fling(find.byType(ImageViewer), const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
      expect(name(tester), 'shot-1.png');
    });

    for (final (width, height) in const [(360.0, 740.0), (1440.0, 900.0)]) {
      testWidgets('no overflow at $width px, text ×1.6', (tester) async {
        await pumpViewer(
          tester,
          images(3),
          width: width,
          height: height,
          textScale: 1.6,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}

class _Loader implements FilePreviewLoader {
  _Loader(this.bytes);

  final Map<String, Uint8List> bytes;
  final Set<String> missing = {};
  final List<EnvironmentPath> asked = [];
  Completer<FilePreviewData>? hold;
  bool fail = false;

  static final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  @override
  Future<FilePreviewData> load(EnvironmentPath path) async {
    asked.add(path);
    if (hold case final hold?) return hold.future;
    if (fail) throw StateError('the distribution is stopped');
    final kind = previewKindFor(path.path);
    if (missing.contains(path.path)) {
      return FilePreviewData(kind: kind, missing: true);
    }
    final found = bytes[path.path] ?? _png;
    return FilePreviewData(kind: kind, size: found.length, bytes: found);
  }
}
