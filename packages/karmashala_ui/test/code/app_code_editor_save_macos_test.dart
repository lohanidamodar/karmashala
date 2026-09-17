import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';

import 'code_editor_harness.dart';

/// Cmd+S from a focused buffer on macOS — its own file, because `re_editor`
/// fixes the platform it reads for the life of the isolate.
void main() {
  testWidgets('Cmd+S in a focused editor saves', (tester) async {
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

    await chord(tester, LogicalKeyboardKey.keyS, meta: true);

    expect(saves, 1);
  }, variant: desktop(TargetPlatform.macOS));
}
