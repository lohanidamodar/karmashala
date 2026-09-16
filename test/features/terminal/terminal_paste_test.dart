import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';

/// Pasting into a pane, and the one case the text-only paste got wrong.
///
/// The report: "i was able to paste image before now in this build i cannot
/// paste image in the terminal claude session here". `Ctrl+V` was bound to
/// xterm's own paste action, which reads `text/plain` and nothing else — so a
/// screenshot on the clipboard pasted *nothing* and the key was swallowed, and
/// Claude Code, which reads the image off the clipboard itself when it sees
/// `^V`, never learned that a paste had been asked for.
///
/// The rule these tests pin down: the app claims the chord only while it has
/// something to paste. With no text on the clipboard a terminal paste can do
/// nothing anyway, so the program gets its key back.
void main() {
  // These cases press `Ctrl+…` by name, so they pin the platform whose command
  // modifier that is. The chord table follows the host — on macOS every one of
  // them is `⌘` instead — and which modifier carries a command is pinned in
  // `shell_shortcuts_platform_test.dart`. What is under test here is what the
  // chord *does*, which is the same on every platform.
  setUp(() => commandKeyIsMeta = false);

  late AppDatabase db;
  late ProviderContainer container;

  /// What `Clipboard.getData` answers. `null` is the image case: a bitmap on
  /// the clipboard is not `text/plain`, and Flutter's clipboard cannot see it.
  String? clipboardText;

  /// Windows fails a clipboard read whenever another app holds the clipboard.
  bool clipboardThrows = false;

  setUp(() {
    db = AppDatabase.memory();
    clipboardText = null;
    clipboardThrows = false;
    container = fakeTerminalContainer(database: db);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  /// Pumps the workbench with one focused pane, and returns it plus everything
  /// it sends to its process.
  Future<(TerminalInstance, List<String>)> pumpPane(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => clipboardThrows
            ? throw PlatformException(code: 'Clipboard error')
            : clipboardText == null
            ? null
            : <String, Object?>{'text': clipboardText},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = container.read(terminalSessionsControllerProvider).activeTab!;
    final instance = controller.instanceFor(tab.focusedPaneId)!;

    final toShell = <String>[];
    instance.terminal.onOutput = toShell.add;
    instance.focusNode.requestFocus();
    await tester.pumpAndSettle();
    return (instance, toShell);
  }

  Future<void> press(WidgetTester tester, {bool shift = false}) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+V pastes the clipboard text', (tester) async {
    clipboardText = 'sk-abc123';
    final (_, toShell) = await pumpPane(tester);

    await press(tester);

    expect(toShell, ['sk-abc123']);
  });

  testWidgets('Ctrl+V with an image on the clipboard reaches the program', (
    tester,
  ) async {
    // The regression. Nothing is pasted, so the key is not ours to keep:
    // Claude Code reads the image itself when `^V` arrives.
    final (_, toShell) = await pumpPane(tester);

    await press(tester);

    expect(toShell, ['\x16']);
  });

  testWidgets('Ctrl+Shift+V follows the same rule', (tester) async {
    final (_, toShell) = await pumpPane(tester);

    await press(tester, shift: true);
    expect(toShell, ['\x16']);

    clipboardText = 'hello';
    toShell.clear();
    await press(tester, shift: true);
    expect(toShell, ['hello']);
  });

  testWidgets('a clipboard that cannot be read is handed on too', (
    tester,
  ) async {
    // `OpenClipboard` fails while another app holds it — a clipboard manager,
    // a browser mid-copy, RDP — and Flutter raises a `PlatformException`.
    // Swallowed, it left Ctrl+V doing nothing whatsoever: no paste, and not
    // even the `^V` that is the whole point of the fallback.
    clipboardThrows = true;
    final (_, toShell) = await pumpPane(tester);

    await press(tester);

    expect(toShell, ['\x16']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty clipboard is handed on rather than pasted', (
    tester,
  ) async {
    clipboardText = '';
    final (_, toShell) = await pumpPane(tester);

    await press(tester);

    expect(toShell, ['\x16']);
  });

  testWidgets('pasting text clears the selection', (tester) async {
    clipboardText = 'hello';
    final (instance, _) = await pumpPane(tester);
    instance.terminal.write('some output');
    await tester.pumpAndSettle();
    final buffer = instance.terminal.buffer;
    instance.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(4, 0),
    );

    await press(tester);

    expect(instance.controller.selection, isNull);
  });

  testWidgets('the right-click Paste item obeys the rule too', (tester) async {
    final (_, toShell) = await pumpPane(tester);

    await tester.tapAt(const Offset(200, 200), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();

    expect(
      toShell,
      ['\x16'],
      reason: 'the menu is the other way to paste, and an image is still an '
          'image when you reach it from a menu',
    );
  });
}
