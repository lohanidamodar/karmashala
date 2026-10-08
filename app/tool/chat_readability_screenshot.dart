// Renders one long, real-looking turn — narration, many tool calls, a failed
// test run, a question, the final answer — at desktop width and on a 390 px
// phone, folded and opened:
//
//   flutter test tool/chat_readability_screenshot.dart --dart-define=SHOT=after
//
// Images land in build/chat-readability-screenshots/<SHOT>-*.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

const _outDir = 'build/chat-readability-screenshots';
const _shot = String.fromEnvironment('SHOT', defaultValue: 'after');

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

final _t0 = DateTime(2026, 10, 8, 14, 2);

ChatMessage _tool(
  int second,
  String name,
  String subject, {
  String output = 'ok',
  bool isError = false,
  int took = 1,
}) => ChatMessage(
  role: 'tool',
  text: name,
  at: _t0.add(Duration(seconds: second)),
  tool: ToolActivity(
    name: name,
    subject: subject,
    output: output,
    isError: isError,
    endedAt: _t0.add(Duration(seconds: second + took)),
  ),
);

ChatMessage _said(int second, String text) => ChatMessage(
  role: 'agent',
  text: text,
  at: _t0.add(Duration(seconds: second)),
);

final _messages = [
  ChatMessage(
    role: 'user',
    text: 'The login test fails on CI. Find out why and fix it.',
    at: _t0,
  ),
  _said(3, 'Let me look at the login flow first.'),
  _tool(4, 'Read', 'app/lib/src/auth/login_page.dart'),
  _tool(5, 'Read', 'app/lib/src/auth/session_guard.dart'),
  _tool(6, 'Grep', 'redirectTo'),
  _tool(7, 'Read', 'app/test/auth/login_test.dart'),
  _tool(8, 'Glob', 'app/lib/src/auth/**/*.dart'),
  _said(10, 'Now I\'ll run the failing test.'),
  _tool(
    11,
    'Bash',
    'flutter test test/auth/login_test.dart',
    isError: true,
    took: 38,
    output:
        'Exit code 1\n'
        'Expected: "/home"\n'
        '  Actual: "/login"\n'
        'Some tests failed.',
  ),
  _said(
    52,
    'The guard redirects before the session is restored, so the test sees '
    '`/login`. Two ways to fix it:\n\n'
    '1. Await the restore in the guard.\n'
    '2. Make the test pump until the restore lands.\n\n'
    'The first is the real bug.',
  ),
  ChatMessage(
    role: 'tool',
    text: 'AskUserQuestion',
    at: _t0.add(const Duration(seconds: 53)),
    tool: const ToolActivity(
      name: 'AskUserQuestion',
      output: 'answered',
      questions: [
        AskedQuestion(
          question: 'Fix the guard, or only the test?',
          answer: 'Fix the guard',
        ),
      ],
    ),
  ),
  _tool(80, 'Edit', 'app/lib/src/auth/session_guard.dart'),
  _tool(82, 'Bash', 'flutter test test/auth/', took: 41, output: 'All passed'),
  _tool(124, 'Bash', 'git diff --stat', output: ' 1 file changed'),
  _said(
    126,
    'Fixed. The guard now waits for the stored session before it decides '
    'where to send you, so a signed-in user lands on `/home` again. I.e. the '
    'redirect no longer races the restore. All 14 auth tests pass.\n\n'
    'The change is one line in `app/lib/src/auth/session_guard.dart`.',
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
    double textScale = 1,
    bool touch = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
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
                child: app!,
              ),
            ),
            home: Scaffold(
              body: ChatTranscriptView(
                messages: _messages,
                turn: TranscriptTurn.idle,
                onPathTap: (_) {},
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
      File(
        '$_outDir/$_shot-$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<void> openFolds(WidgetTester tester) async {
    for (final line in find.textContaining('Worked for').evaluate().toList()) {
      await tester.tap(find.byWidget(line.widget).first);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('desktop', (tester) async {
    final key = await pump(tester, const Size(1100, 1000));
    await shoot(tester, key, 'desktop');
    await openFolds(tester);
    await shoot(tester, key, 'desktop-open');
  });

  testWidgets('phone', (tester) async {
    final key = await pump(tester, const Size(390, 1400), touch: true);
    await shoot(tester, key, 'phone');
  });

  testWidgets('phone at text x1.6', (tester) async {
    final key = await pump(
      tester,
      const Size(390, 1900),
      touch: true,
      textScale: 1.6,
    );
    await shoot(tester, key, 'phone-1.6');
  });
}
