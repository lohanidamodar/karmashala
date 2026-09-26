import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import '../../support/test_machine.dart';

/// `Ctrl+C` in a terminal pane means two different things, and which one is
/// decided by whether there is a selection *right now*.
///
/// This is Windows Terminal's and VS Code's rule. It cannot be a chord in the
/// static map beside `Ctrl+V`, because it is not a setting: the same key is
/// copy or interrupt depending on the state of one pane at one moment.
void main() {
  // These cases press `Ctrl+…` by name, so they pin the platform whose command
  // modifier that is. The chord table follows the host — on macOS every one of
  // them is `⌘` instead — and which modifier carries a command is pinned in
  // `shell_shortcuts_platform_test.dart`. What is under test here is what the
  // chord *does*, which is the same on every platform.
  setUp(() => commandKeyIsMeta = false);

  late TestMachine db;
  late ProviderContainer container;
  String? clipboard;

  setUp(() {
    db = TestMachine();
    clipboard = null;
    container = fakeTerminalContainer(machine: db);
  });

  tearDown(() {
    container.dispose();
  });

  /// Pumps the workbench with one pane holding [output], and returns that pane
  /// plus everything it sends to its process.
  Future<(TerminalInstance, List<String>)> pumpPane(
    WidgetTester tester,
    String output,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
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
    instance.terminal.write(output);
    await tester.pumpAndSettle();

    final toShell = <String>[];
    instance.terminal.onOutput = toShell.add;
    instance.focusNode.requestFocus();
    await tester.pumpAndSettle();
    return (instance, toShell);
  }

  /// Selects cells [from]..[to] on the first row.
  void select(TerminalInstance instance, int from, int to) {
    final buffer = instance.terminal.buffer;
    instance.controller.setSelection(
      buffer.createAnchor(from, 0),
      buffer.createAnchor(to, 0),
    );
  }

  Future<void> ctrlC(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('with a selection, Ctrl+C copies and sends nothing', (
    tester,
  ) async {
    final (instance, toShell) = await pumpPane(tester, 'hello world');
    select(instance, 0, 5);

    await ctrlC(tester);

    expect(clipboard, 'hello');
    expect(
      toShell,
      isEmpty,
      reason: 'the interrupt must not also be sent, or the copy kills the job',
    );
  });

  testWidgets('copying clears the selection, so the next Ctrl+C interrupts', (
    tester,
  ) async {
    // The point of the whole rule: the second press is the one you make
    // because the first did not stop the program.
    final (instance, toShell) = await pumpPane(tester, 'hello world');
    select(instance, 0, 5);

    await ctrlC(tester);
    expect(instance.controller.selection, isNull);

    await ctrlC(tester);
    expect(toShell, ['\x03']);
  });

  testWidgets('with no selection, Ctrl+C is the interrupt it always was', (
    tester,
  ) async {
    final (instance, toShell) = await pumpPane(tester, 'hello world');
    expect(instance.controller.selection, isNull);

    await ctrlC(tester);

    expect(toShell, ['\x03']);
    expect(clipboard, isNull, reason: 'nothing was copied');
  });

  testWidgets('Ctrl+Shift+C copies without touching the interrupt', (
    tester,
  ) async {
    final (instance, toShell) = await pumpPane(tester, 'hello world');
    select(instance, 6, 11);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(clipboard, 'world');
    expect(toShell, isEmpty);
  });
}
