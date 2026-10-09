// Renders round 76's review in the editor: a session's uncommitted hunks in
// the gutter, the change strip, a waiting comment and the comment form, on a
// desktop and at 390 px. Under tool/ so `flutter test` never picks it up; run
// it explicitly from app/:
//
//   flutter test tool/editor_review_r76_screenshot.dart
//
// Images land in build/editor-review-r76/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/editor_change_review.dart';
import 'package:karmashala/src/features/editor/application/review_comments.dart';
import 'package:karmashala/src/features/editor/presentation/editor_change_review_view.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart'
    show diffForTargetProvider;
import 'package:karmashala/src/features/sessions/application/hunk_review_marks.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';

const _outDir = 'build/editor-review-r76';

const _diff =
    'diff --git a/lib/scores.dart b/lib/scores.dart\n'
    '--- a/lib/scores.dart\n'
    '+++ b/lib/scores.dart\n'
    '@@ -1,13 +1,12 @@\n'
    ' class Scores {\n'
    '   Scores(this.players);\n'
    ' \n'
    '   final List<Player> players;\n'
    ' \n'
    '-  int scoreOf(String name) {\n'
    '-    for (final p in players) {\n'
    '-      if (p.name == name) return p.score;\n'
    '-    }\n'
    '-    return 0;\n'
    '-  }\n'
    '+  late final Map<String, int> _byName = {\n'
    '+    for (final p in players) p.name: p.score,\n'
    '+  };\n'
    '+\n'
    '+  int scoreOf(String name) => _byName[name] ?? 0;\n'
    ' \n'
    '   int get total {\n'
    '@@ -23,6 +22,5 @@\n'
    '   String describe() {\n'
    '     final best = players.reduce(_higher);\n'
    '-    print(best);\n'
    '     return "\${best.name} leads with \${best.score}";\n'
    '   }\n'
    ' }\n';

const _file = '''class Scores {
  Scores(this.players);

  final List<Player> players;

  late final Map<String, int> _byName = {
    for (final p in players) p.name: p.score,
  };

  int scoreOf(String name) => _byName[name] ?? 0;

  int get total {
    var sum = 0;
    for (final p in players) {
      sum += p.score;
    }
    return sum;
  }

  Player _higher(Player a, Player b) => a.score >= b.score ? a : b;

  String describe() {
    final best = players.reduce(_higher);
    return "\${best.name} leads with \${best.score}";
  }
}
''';

const _target = EditorReviewTarget(
  sessionId: 's1',
  sessionTitle: 'Speed up the score lookup',
  repositoryId: 'app',
  checkout: EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
  relativePath: 'lib/scores.dart',
);

class _OneWaiting extends ReviewCommentDrafts {
  @override
  Map<String, List<ReviewComment>> build() => const {
    's1': [
      ReviewComment(
        id: 'a',
        repositoryId: 'app',
        path: 'lib/scores.dart',
        startLine: 22,
        endLine: 22,
        note: 'keep a debug log here, behind a flag',
        quote: '-    print(best);',
      ),
    ],
  };
}

Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    bool form = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final marks = Directory.systemTemp.createTempSync('ks-r76-shot');
    final controller = CodeLineEditingController.fromText(_file);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ProviderScope(
          overrides: [
            editorReviewTargetProvider.overrideWith((ref, id) => _target),
            diffForTargetProvider.overrideWith((ref, target) async => _diff),
            hunkReviewMarksDirectoryProvider.overrideWithValue(
              () async => marks,
            ),
            reviewCommentDraftsProvider.overrideWith(_OneWaiting.new),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            home: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const PaneHeader(
                    icon: AppIcons.fileCode,
                    title: 'scores.dart',
                  ),
                  Expanded(
                    child: EditorChangeReview(
                      documentId: 'doc',
                      controller: controller,
                      isDirty: false,
                      editor: (hooks) => AppCodeEditor(
                        controller: controller,
                        language: 'dart',
                        changeMarks: hooks?.marks,
                        onChangeMarkTap: hooks?.onMarkTap,
                        onNextChange: hooks?.onNext,
                        onPreviousChange: hooks?.onPrevious,
                      ),
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
    if (form) {
      await tester.tap(find.byKey(const ValueKey('editor-review-comment')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('editor-review-note')),
        'this loop was fine for 4 players; is the map worth it?',
      );
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    marks.deleteSync(recursive: true);
  }

  testWidgets(
    'desktop',
    (t) => shoot(t, 'desktop', size: const Size(1200, 700)),
  );
  testWidgets(
    'desktop comment',
    (t) => shoot(t, 'desktop-comment', size: const Size(1200, 700), form: true),
  );
  testWidgets(
    'phone',
    (t) => shoot(t, 'phone-390', size: const Size(390, 844)),
  );
  testWidgets(
    'phone comment',
    (t) =>
        shoot(t, 'phone-390-comment', size: const Size(390, 844), form: true),
  );
}
