// Renders the composer's "@" list at desktop width and on a 390 px phone (the
// list and the sheet the @ button opens), a message with chips, and what the
// agent receives once it is sent:
//
//   flutter test tool/mentions_r73_screenshot.dart
//
// Images and the sent text land in build/mentions-r73-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_mentions.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

const _outDir = 'build/mentions-r73-screenshots';

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

class _Reads implements MentionReads {
  @override
  Future<({List<String> files, String? gitignore})> files() async => (
    files: const [
      'app/lib/main.dart',
      'app/lib/src/features/sessions/presentation/message_composer.dart',
      'app/lib/src/features/sessions/application/session_mentions.dart',
      'app/test/features/sessions/composer_mentions_test.dart',
      'app/build/app.dill',
      'server/lib/src/acp/acp_session_runtime.dart',
      'README.md',
      'PROJECT.md',
    ],
    gitignore: 'build/\n',
  );

  @override
  Future<String> diff(String base) async =>
      'diff --git a/app/lib/main.dart b/app/lib/main.dart\n'
      '--- a/app/lib/main.dart\n+++ b/app/lib/main.dart\n'
      '@@ -1,3 +1,4 @@\n import \'package:flutter/material.dart\';\n'
      '+import \'src/app/bootstrap.dart\';\n';

  @override
  List<MentionTerminal> terminals() => const [
    MentionTerminal(id: 't1', title: 'flutter run', detail: '~/karmashala/app'),
    MentionTerminal(id: 't2', title: 'pwsh'),
  ];

  @override
  String? terminalTail(String id, int lines) =>
      'Launching lib/main.dart on Windows in debug mode...\n'
      'lib/src/app/bootstrap.dart:12:3: Error: Undefined name \'runKarmashala\'.\n'
      'Error: Build failed.';

  @override
  List<MentionSession> sessions() => const [
    MentionSession(id: 's2', title: 'Fix login redirect'),
    MentionSession(id: 's3', title: 'Release notes 1.35'),
  ];

  @override
  List<MentionSession> subagents() => const [
    MentionSession(id: 's4', title: 'round 72 checks'),
  ];

  @override
  Future<String?> lastAnswer(String id) async =>
      'The redirect now waits for the session guard; see lib/src/auth.';
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    Directory(_outDir).createSync(recursive: true);
  });

  late MentionTextController controller;
  final sent = <String>[];

  Future<GlobalKey> pump(
    WidgetTester tester,
    Size size, {
    bool touch = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    controller = MentionTextController();
    addTearDown(controller.dispose);
    final key = GlobalKey();
    final density = touch ? UiDensity.touch : UiDensity.pointer;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: density.themeFor(AppTheme.dark()),
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: UiDensityScope(density: density, child: app!),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Column(
                children: [
                  const Expanded(child: SizedBox()),
                  Center(
                    child: MessageComposer(
                      hintText: 'Message the agent…',
                      controller: controller,
                      mentions: SessionMentions(_Reads()),
                      onSend: (text) async => sent.add(text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
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

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  testWidgets('desktop: the list on "@"', (tester) async {
    final key = await pump(tester, const Size(1100, 640));
    await type(tester, 'Why does the build fail? Look at @');
    await shoot(tester, key, 'desktop-list');
    await type(tester, 'Why does the build fail? Look at @comp');
    await shoot(tester, key, 'desktop-list-files');
    await type(tester, 'Why does the build fail? Look at @terminal:');
    await shoot(tester, key, 'desktop-list-terminals');
  });

  testWidgets('desktop: a message with chips, and what the agent received', (
    tester,
  ) async {
    final key = await pump(tester, const Size(1100, 420));
    await type(
      tester,
      'Why does @terminal:"flutter run" fail after @diff in '
      '@app/lib/main.dart? Compare @session:"Fix login redirect" ',
    );
    await shoot(tester, key, 'desktop-chips');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      File('$_outDir/agent-received.txt').writeAsStringSync(sent.last);
    });

    tester.view.physicalSize = const Size(900, 900);
    final view = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: view,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: ChatTranscriptView(
              messages: [ChatMessage(role: 'user', text: sent.last)],
              onPathTap: (_) {},
              onLinkTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await shoot(tester, view, 'agent-received');
  });

  testWidgets('phone 390: the list, and the sheet the @ button opens', (
    tester,
  ) async {
    var key = await pump(tester, const Size(390, 844), touch: true);
    await type(tester, 'Check @ses');
    await shoot(tester, key, 'phone-list');

    key = await pump(tester, const Size(390, 844), touch: true);
    await type(tester, 'Check');
    await tester.tap(find.byKey(const ValueKey('composer-mention-button')));
    await tester.pumpAndSettle();
    await shoot(tester, key, 'phone-sheet');

    key = await pump(tester, const Size(390, 844), touch: true, textScale: 1.6);
    await type(tester, 'Check @diff and @');
    await shoot(tester, key, 'phone-list-x1.6');
  });
}
