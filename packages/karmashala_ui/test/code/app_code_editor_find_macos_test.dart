import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/tokens.dart';

import 'code_editor_harness.dart';

/// The macOS chords for find: ⌘F, ⌥⌘F, ⌘G / ⇧⌘G and ⌃G — the last because ⌘L
/// is `re_editor`'s select-line and ⌘G is find next.
void main() {
  final mac = desktop(TargetPlatform.macOS);

  testWidgets('⌘F, ⌘G and ⇧⌘G find and step; ⌥⌘F opens replace', (
    tester,
  ) async {
    final controller = CodeLineEditingController.fromText('one two one\none\n');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      AppCodeEditor(controller: controller, focusNode: focus),
    );
    final search = tester
        .state<AppCodeEditorState>(find.byType(AppCodeEditor))
        .findController;

    await chord(tester, LogicalKeyboardKey.keyF, meta: true);
    expect(search.isOpen, isTrue);
    search.findInputController.text = 'one';
    await tester.pump(Latency.searchDebounce);
    await tester.pump();
    expect(search.matchCount, 3);
    expect(find.byTooltip('Next match (⌘G)'), findsOneWidget);

    await chord(tester, LogicalKeyboardKey.keyG, meta: true);
    expect(search.currentIndex, 1);
    await chord(tester, LogicalKeyboardKey.keyG, meta: true, shift: true);
    expect(search.currentIndex, 0);

    focus.requestFocus();
    await tester.pump();
    await chord(tester, LogicalKeyboardKey.keyF, meta: true, alt: true);
    expect(search.replaceShown, isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
  }, variant: mac);

  testWidgets('⌃G opens go to line', (tester) async {
    final controller = CodeLineEditingController.fromText('a\nb\nc\n');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      AppCodeEditor(controller: controller, focusNode: focus),
    );

    await chord(tester, LogicalKeyboardKey.keyG, control: true);
    await tester.pumpAndSettle();
    expect(find.text('Go to line'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
  }, variant: mac);
}
