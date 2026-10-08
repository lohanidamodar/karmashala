// Renders a conversation whose messages name pictures — one, several, and one
// in markdown — into PNGs, phone and desktop. The pictures are the
// Automations renders, so run tool/automations_screenshot.dart first:
//
//   flutter test tool/automations_screenshot.dart
//   flutter test tool/chat_images_screenshot.dart
//
// Images land in build/chat-images-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/file_preview_loader.dart';
import 'package:karmashala/src/features/sessions/domain/file_preview_kind.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_inline_images.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

const _shots = 'build/automations-screenshots';
const _outDir = 'build/chat-images-screenshots';

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

/// Reads the renders off this disk, as the server's files API would.
class _DiskLoader implements FilePreviewLoader {
  @override
  Future<FilePreviewData> load(EnvironmentPath path) async {
    final bytes = File(
      '$_shots/${path.path.split('/').last}',
    ).readAsBytesSync();
    return FilePreviewData(
      kind: previewKindFor(path.path),
      size: bytes.length,
      bytes: Uint8List.fromList(bytes),
    );
  }
}

const _messages = [
  ChatMessage(role: 'user', text: 'Render the Automations tab on a phone.'),
  ChatMessage(
    role: 'agent',
    text: 'Done. The phone render is shots/grid-390-x1.0.png.',
  ),
  ChatMessage(role: 'user', text: 'And every desktop width?'),
  ChatMessage(
    role: 'agent',
    text:
        'Saved shots/grid-1100-x1.0.png, shots/grid-1440-x1.0.png, '
        'shots/grid-1920-x1.0.png and shots/grid-1440-x1.6.png.',
  ),
  ChatMessage(
    role: 'agent',
    text: 'In markdown:\n\n![the editor](shots/editor-desktop-dark.png)',
  ),
];

void main() {
  setUpAll(() async {
    await _loadFonts();
    Directory(_outDir).createSync(recursive: true);
  });

  for (final (form, size) in const [
    ('desktop', Size(1440, 1400)),
    ('phone', Size(390, 1600)),
  ]) {
    testWidgets('chat $form', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            filePreviewLoaderProvider.overrideWithValue(_DiskLoader()),
          ],
          child: RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.dark(),
              home: Scaffold(
                body: TranscriptInlineImages(
                  place: (path) =>
                      EnvironmentPath(environmentId: 'local', path: path),
                  onOpen: (_) {},
                  child: const ChatTranscriptView(messages: _messages),
                ),
              ),
            ),
          ),
        ),
      );
      // Pictures decode off the test clock.
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          final image = element.widget as Image;
          await precacheImage(image.image, element);
        }
      });
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '$_outDir/chat-$form.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    });
  }
}
