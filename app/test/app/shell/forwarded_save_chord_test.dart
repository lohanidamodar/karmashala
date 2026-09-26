import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala_ui/code.dart';

/// macOS hands Cmd chords back over a channel when its text-input plugin would
/// eat them. Cmd+S belongs to the focused document, not to the shell, so the
/// forwarded chord is invoked where focus is.
void main() {
  testWidgets('a forwarded Cmd+S saves the focused editor', (tester) async {
    final controller = CodeLineEditingController.fromText('a');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppCodeEditor(
            controller: controller,
            focusNode: focus,
            onSave: () => saves++,
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();

    expect(focusedCommandChords.keys, contains('s'));
    expect(invokeFocusedCommandChord('s', shift: false), isTrue);
    expect(saves, 1);

    // Shifted, or a key nobody focused takes, is left to the shell's chords.
    expect(invokeFocusedCommandChord('s', shift: true), isFalse);
    expect(invokeFocusedCommandChord('k', shift: false), isFalse);
    expect(saves, 1);

    // The caret blinks on a timer; unfocused and unmounted, it stops.
    focus.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nothing focused that saves means the chord is not taken', (
    tester,
  ) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(focusNode: field)),
      ),
    );
    field.requestFocus();
    await tester.pump();

    expect(invokeFocusedCommandChord('s', shift: false), isFalse);
  });
}
