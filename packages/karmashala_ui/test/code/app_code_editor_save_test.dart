import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';

import 'code_editor_harness.dart';

/// Ctrl+S from a focused buffer on Windows and Linux. `re_editor` binds the
/// chord to an intent of its own that does nothing and still consumes the key,
/// so a binding above the editor never heard it.
void main() {
  testWidgets('Ctrl+S in a focused editor saves', (tester) async {
    final controller = CodeLineEditingController.fromText('a\nb\n');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var saves = 0;
    await pumpEditor(
      tester,
      AppCodeEditor(
        controller: controller,
        focusNode: focus,
        onSave: () => saves++,
      ),
    );
    expect(focus.hasFocus, isTrue);

    await chord(tester, LogicalKeyboardKey.keyS, control: true);

    expect(saves, 1);
  }, variant: desktop(TargetPlatform.linux));

  testWidgets('a read-only viewer does not claim the chord it cannot use', (
    tester,
  ) async {
    final controller = CodeLineEditingController.fromText('a\n');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await pumpEditor(
      tester,
      AppCodeEditor(controller: controller, focusNode: focus, readOnly: true),
    );

    // Nothing to assert beyond "no throw": with no onSave there is no save.
    await chord(tester, LogicalKeyboardKey.keyS, control: true);
    expect(tester.takeException(), isNull);
  }, variant: desktop(TargetPlatform.linux));
}
