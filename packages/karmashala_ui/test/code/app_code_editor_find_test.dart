import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'code_editor_harness.dart';

/// Find, replace and go to line in the editor, driven by the keys a user
/// presses on Windows and Linux. macOS chords are in their own file, because
/// `re_editor` reads the platform once per isolate.
void main() {
  const text = 'alpha beta\nBeta gamma beta\nbetamax\n';
  final linux = desktop(TargetPlatform.linux);

  late CodeLineEditingController controller;
  late FocusNode focus;

  AppCodeFindController findOf(WidgetTester tester) => tester
      .state<AppCodeEditorState>(find.byType(AppCodeEditor))
      .findController;

  Future<void> open(
    WidgetTester tester, {
    String body = text,
    bool readOnly = false,
    Size size = const Size(800, 600),
  }) async {
    controller = CodeLineEditingController.fromText(body);
    focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      AppCodeEditor(
        controller: controller,
        focusNode: focus,
        readOnly: readOnly,
      ),
      size: size,
    );
  }

  /// Lets the debounce pass and the result land.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(Latency.searchDebounce);
    await tester.pump();
  }

  /// Stops the carets blinking so no timer outlives the test.
  Future<void> teardown(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> typeQuery(WidgetTester tester, String query) async {
    findOf(tester).findInputController.text = query;
    await settle(tester);
  }

  testWidgets('Ctrl+F opens the strip on the query field, and counts', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    final search = findOf(tester);

    expect(search.isOpen, isTrue);
    expect(find.byType(CodeFindBar), findsOneWidget);
    expect(search.findInputFocusNode.hasFocus, isTrue);

    await typeQuery(tester, 'beta');
    expect(search.matchCount, 4, reason: 'case-insensitive by default');
    expect(find.text('1 of 4'), findsOneWidget);
    await teardown(tester);
  }, variant: linux);

  testWidgets('the query waits for typing to pause before searching', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    final search = findOf(tester);

    search.findInputController.text = 'gam';
    await tester.pump();
    expect(search.isSearching, isTrue);
    expect(search.matchCount, 0);

    await settle(tester);
    expect(search.isSearching, isFalse);
    expect(search.matchCount, 1);
    await teardown(tester);
  }, variant: linux);

  testWidgets('a single-line selection fills the query', (tester) async {
    await open(tester);
    controller.selection = const CodeLineSelection(
      baseIndex: 1,
      baseOffset: 5,
      extentIndex: 1,
      extentOffset: 10,
    );
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    await tester.pump();

    final search = findOf(tester);
    expect(search.findInputController.text, 'gamma');
    expect(search.matchCount, 1);
    await teardown(tester);
  }, variant: linux);

  testWidgets('Enter and Shift+Enter step, wrap, select and highlight', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    await typeQuery(tester, 'beta');
    final search = findOf(tester);
    expect(search.currentIndex, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(search.currentIndex, 1);
    expect(find.text('2 of 4'), findsOneWidget);
    // The current match is the selection, drawn stronger than the rest.
    expect(controller.selection, search.currentMatchSelection);
    expect(controller.selectedText, 'Beta');
    expect(search.allMatchSelections, hasLength(4));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(search.currentIndex, 0, reason: 'past the last wraps to the first');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(
      search.currentIndex,
      3,
      reason: 'before the first wraps to the last',
    );
    await teardown(tester);
  }, variant: linux);

  testWidgets('F3 and Shift+F3 step from inside the buffer', (tester) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    await typeQuery(tester, 'beta');
    final search = findOf(tester);
    focus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();
    expect(search.currentIndex, 1);
    expect(controller.selectedText, 'Beta');

    await chord(tester, LogicalKeyboardKey.f3, shift: true);
    expect(search.currentIndex, 0);
    expect(focus.hasFocus, isTrue, reason: 'stepping leaves focus where it is');
    await teardown(tester);
  }, variant: linux);

  testWidgets('match case, whole word and regex each narrow the matches', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    await typeQuery(tester, 'beta');
    final search = findOf(tester);
    expect(search.matchCount, 4);

    await tester.tap(find.byTooltip('Match case (Ctrl+Alt+C)'));
    await tester.pump();
    expect(search.caseSensitive, isTrue);
    expect(search.matchCount, 3);

    await tester.tap(find.byTooltip('Match whole word (Ctrl+Alt+W)'));
    await tester.pump();
    expect(search.matchCount, 2, reason: '"betamax" is not the word');

    await tester.tap(find.byTooltip('Match whole word (Ctrl+Alt+W)'));
    await tester.tap(find.byTooltip('Match case (Ctrl+Alt+C)'));
    await tester.tap(find.byTooltip('Use regular expression (Ctrl+Alt+R)'));
    await tester.pump();
    await typeQuery(tester, r'^b\w+');
    expect(search.regex, isTrue);
    expect(search.matchCount, 2);
    await teardown(tester);
  }, variant: linux);

  testWidgets('the option chords work from the find field and the buffer', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    final search = findOf(tester);
    expect(search.findInputFocusNode.hasFocus, isTrue);

    await chord(tester, LogicalKeyboardKey.keyC, control: true, alt: true);
    await chord(tester, LogicalKeyboardKey.keyW, control: true, alt: true);
    await chord(tester, LogicalKeyboardKey.keyR, control: true, alt: true);
    expect(
      (search.caseSensitive, search.wholeWord, search.regex),
      (true, true, true),
    );

    focus.requestFocus();
    await tester.pump();
    await chord(tester, LogicalKeyboardKey.keyC, control: true, alt: true);
    await chord(tester, LogicalKeyboardKey.keyW, control: true, alt: true);
    await chord(tester, LogicalKeyboardKey.keyR, control: true, alt: true);
    expect(
      (search.caseSensitive, search.wholeWord, search.regex),
      (false, false, false),
      reason: 'each chord toggles once, not once per binding',
    );
    await teardown(tester);
  }, variant: linux);

  testWidgets('an invalid regex says so inline and never throws', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    final search = findOf(tester);
    search.toggleRegex();
    await typeQuery(tester, 'be(ta');

    expect(tester.takeException(), isNull);
    expect(search.patternError, isNotNull);
    expect(search.matchCount, 0);
    expect(find.text('Invalid pattern'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await teardown(tester);
  }, variant: linux);

  testWidgets('Esc closes the strip and hands focus back to the buffer', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    await typeQuery(tester, 'beta');
    final search = findOf(tester);
    expect(search.findInputFocusNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(search.isOpen, isFalse);
    expect(find.byType(TextField), findsNothing, reason: 'the strip is gone');
    expect(focus.hasFocus, isTrue);
    expect(search.allMatchSelections, isNull, reason: 'no highlight left');
    await teardown(tester);
  }, variant: linux);

  testWidgets('an edit hides stale highlights until the search re-runs', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    await typeQuery(tester, 'beta');
    final search = findOf(tester);
    expect(search.matchCount, 4);

    controller.text = 'beta\n';
    await tester.pump();
    expect(search.allMatchSelections, isNull);

    await settle(tester);
    expect(search.matchCount, 1);
    await teardown(tester);
  }, variant: linux);

  testWidgets('Ctrl+H replaces one, then all as a single undo step', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyH, control: true);
    final search = findOf(tester);
    expect(search.replaceShown, isTrue);
    await typeQuery(tester, 'beta');
    search.replaceInputController.text = 'delta';
    await tester.pump();

    await tester.tap(find.byTooltip('Replace (Enter)'));
    await tester.pump();
    expect(controller.text, 'alpha delta\nBeta gamma beta\nbetamax\n');
    expect(search.matchCount, 3);
    expect(search.currentMatchSelection?.baseIndex, 1, reason: 'moves on');

    await tester.tap(find.byTooltip('Replace all (Ctrl+Alt+Enter)'));
    await tester.pump();
    expect(controller.text, 'alpha delta\ndelta gamma delta\ndeltamax\n');
    expect(search.matchCount, 0);

    controller.undo();
    await tester.pump();
    expect(controller.text, 'alpha delta\nBeta gamma beta\nbetamax\n');
    await teardown(tester);
  }, variant: linux);

  testWidgets('a read-only buffer finds but never replaces', (tester) async {
    await open(tester, readOnly: true);
    await chord(tester, LogicalKeyboardKey.keyH, control: true);
    final search = findOf(tester);
    expect(search.replaceShown, isFalse);

    await chord(tester, LogicalKeyboardKey.keyF, control: true);
    await typeQuery(tester, 'beta');
    expect(search.matchCount, 4);
    expect(find.byTooltip('Show replace'), findsNothing);

    search.replaceMode();
    search.replaceInputController.text = 'x';
    search.replaceAllMatches();
    search.replaceMatch();
    await tester.pump();
    expect(search.replaceShown, isFalse);
    expect(controller.text, text);
    await teardown(tester);
  }, variant: linux);

  testWidgets('Ctrl+G goes to a line, and refuses one that is not there', (
    tester,
  ) async {
    await open(tester);
    await chord(tester, LogicalKeyboardKey.keyG, control: true);
    await tester.pumpAndSettle();
    expect(find.text('Go to line'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '99');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Line must be between 1 and 4'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '2:6');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Go to line'), findsNothing);
    expect(controller.selection.baseIndex, 1);
    expect(controller.selection.baseOffset, 5);
    expect(controller.selection.isCollapsed, isTrue);
    expect(focus.hasFocus, isTrue);
    await teardown(tester);
  }, variant: linux);

  test('go to line parses line and line:column against the buffer', () {
    final buffer = CodeLineEditingController.fromText('ab\ncdef\n');
    addTearDown(buffer.dispose);
    expect(
      parseGoToLine('2', buffer).position,
      const CodeLinePosition(index: 1, offset: 0),
    );
    expect(
      parseGoToLine(' 2 : 5 ', buffer).position,
      const CodeLinePosition(index: 1, offset: 4),
    );
    expect(
      parseGoToLine('2:6', buffer).error,
      'Column must be between 1 and 5',
    );
    expect(parseGoToLine('0', buffer).error, isNotNull);
    expect(parseGoToLine('x', buffer).error, isNotNull);
  });

  testWidgets(
    'a 50,000-line buffer searches off the UI thread and paints only nearby',
    (tester) async {
      final body = List.generate(
        50000,
        (i) => 'line $i hay abcdefghijklmnop',
      ).join('\n');
      await open(tester, body: body);
      await chord(tester, LogicalKeyboardKey.keyF, control: true);
      final search = findOf(tester);
      expect(body.length, greaterThan(kCodeSearchOffThreadChars));

      final clock = Stopwatch()..start();
      search.findInputController.text = 'line';
      await tester.pump(Latency.searchDebounce);
      await tester.pump();
      clock.stop();
      // The search was handed off: the frames that started it came back
      // without its result.
      expect(search.isSearching, isTrue);
      expect(clock.elapsedMilliseconds, lessThan(1000));

      for (var i = 0; i < 200 && search.isSearching; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(search.matchCount, 50000);
      final painted = search.allMatchSelections!;
      expect(painted.length, lessThan(kCodeHighlightAllBelow));
      expect(painted.first.baseIndex, 0, reason: 'the top is on screen');
      await teardown(tester);
    },
    variant: linux,
  );

  for (final width in [240.0, 320.0, 640.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('the strip fits a ${width}px pane at ${scale}x text', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        controller = CodeLineEditingController.fromText(text);
        focus = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 300,
                  child: AppCodeEditor(
                    controller: controller,
                    focusNode: focus,
                  ),
                ),
              ),
            ),
          ),
        );
        focus.requestFocus();
        await tester.pump();
        await chord(tester, LogicalKeyboardKey.keyH, control: true);
        await typeQuery(tester, 'beta');

        expect(tester.takeException(), isNull);
        final narrow =
            width <
            WidthClass.scaleBreakpoint(
              CodeFindBar.foldTogglesBelow,
              TextScaler.linear(scale),
            );
        expect(
          find.byTooltip('Find options'),
          narrow ? findsOneWidget : findsNothing,
        );
        for (final tooltip in ['Close (Esc)', 'Replace (Enter)']) {
          final rect = tester.getRect(find.byTooltip(tooltip));
          expect(rect.right, lessThanOrEqualTo(width + 0.5), reason: tooltip);
        }
        expect(tester.getRect(find.byType(CodeFindBar)).width, width);
        await teardown(tester);
      }, variant: linux);
    }
  }
}
