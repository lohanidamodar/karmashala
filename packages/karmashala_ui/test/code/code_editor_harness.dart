import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/theme.dart';

/// `re_editor` reads the platform once per isolate, so a test file that sends
/// keys sticks to one target platform for every test in it.
TargetPlatformVariant desktop(TargetPlatform platform) =>
    TargetPlatformVariant.only(platform);

/// Pumps [editor] focused, in a pane of [size].
Future<void> pumpEditor(
  WidgetTester tester,
  AppCodeEditor editor, {
  Size size = const Size(800, 600),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: editor,
          ),
        ),
      ),
    ),
  );
  editor.focusNode?.requestFocus();
  await tester.pump();
  await tester.pump();
}

/// Presses [key] with [modifiers] held, the way a keyboard sends a chord.
Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool meta = false,
  bool shift = false,
  bool alt = false,
}) async {
  final held = [
    if (control) LogicalKeyboardKey.controlLeft,
    if (meta) LogicalKeyboardKey.metaLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
    if (alt) LogicalKeyboardKey.altLeft,
  ];
  for (final k in held) {
    await tester.sendKeyDownEvent(k);
  }
  await tester.sendKeyEvent(key);
  for (final k in held.reversed) {
    await tester.sendKeyUpEvent(k);
  }
  await tester.pump();
}
