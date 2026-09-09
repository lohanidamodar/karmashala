// The mobile pane against the terminal, competing for one keyboard.
//
// This is a regression test for a bug the owner hit in the running app:
// clicking the device mirror appeared to do nothing, and what they typed went
// into the shell instead. The click was never the problem — it takes focus on
// the first frame, and the first keystroke does reach the device. What went
// wrong came after: `TerminalSessionsController._focusActivePane` re-requests
// the active pane's focus in a post-frame callback, and its only guard was
// "is the keyboard in an `EditableText`". A device mirror is a `Focus`, not an
// `EditableText`, so the guard passed and the keyboard was taken back.
//
// A real `TerminalView` is used rather than a stand-in `Focus`, because the
// half of the bug worth pinning is that the terminal *accepts* the keystroke
// once it holds focus — a bare `FocusNode` would prove only that focus moved.
// The controller itself is not driven: it needs a PTY, a layout DAO and a
// session tree, and none of that is what broke. What is exercised is the exact
// guard it now calls, at the exact call shape it calls it in.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/widgets/keyboard_capture.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/devices/presentation/device_keyboard_surface.dart';
import 'package:xterm2/xterm.dart';

class _RecordingSink implements DeviceKeyboardSink {
  final List<DeviceKeyIntent> sent = [];

  @override
  DeviceKeyboardTransport get transport =>
      DeviceKeyboardTransport.scrcpyControl;

  @override
  String? refusal;

  @override
  bool send(DeviceKeyIntent intent) {
    sent.add(intent);
    return true;
  }

  List<String> get text => [
    for (final intent in sent)
      if (intent is DeviceTextIntent) intent.text,
  ];
}

void main() {
  late Terminal terminal;
  late FocusNode terminalFocus;
  late _RecordingSink sink;
  late List<String> shellSaw;

  setUp(() {
    terminal = Terminal();
    terminalFocus = FocusNode(debugLabel: 'terminal');
    sink = _RecordingSink();
    shellSaw = <String>[];
    terminal.onOutput = shellSaw.add;
  });

  tearDown(() => terminalFocus.dispose());

  /// A terminal and a device mirror side by side, the way the shell lays out a
  /// workbench and the side panel.
  Future<void> pumpBoth(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: TerminalView(
                  terminal,
                  focusNode: terminalFocus,
                  autofocus: true,
                  hardwareKeyboardOnly: true,
                ),
              ),
              Expanded(
                child: DeviceKeyboardSurface(
                  sink: sink,
                  deviceLabel: 'CPH1989',
                  child: const SizedBox.expand(
                    child: ColoredBox(color: Color(0xFF000000)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> clickTheMirror(WidgetTester tester) async {
    await tester.tap(find.byType(DeviceKeyboardSurface));
    await tester.pump();
    await tester.pump();
  }

  /// What `TerminalSessionsController._focusActivePane` does once its pending
  /// rebuild has been laid out.
  void focusActivePane() {
    if (keyboardIsSpokenFor()) return;
    terminalFocus.requestFocus();
  }

  testWidgets('the terminal starts with the keyboard, as it should', (
    tester,
  ) async {
    await pumpBoth(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();

    expect(shellSaw, ['a']);
    expect(sink.sent, isEmpty);
  });

  testWidgets('clicking the mirror moves the keyboard to the device', (
    tester,
  ) async {
    await pumpBoth(tester);
    await clickTheMirror(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();

    expect(sink.text, ['h']);
    expect(shellSaw, isEmpty);
  });

  testWidgets('and the terminal cannot take it back while it is forwarding', (
    tester,
  ) async {
    // The bug, exactly: a tab opening, a pane closing, a split resizing — any
    // of the fifteen things that call `_focusActivePane` — used to land here
    // and quietly redirect the next keystroke into the shell.
    await pumpBoth(tester);
    await clickTheMirror(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();

    focusActivePane();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();

    expect(sink.text, ['h', 'i']);
    expect(shellSaw, isEmpty, reason: 'the shell must not see either key');
  });

  testWidgets('but it may take it back once forwarding is stopped', (
    tester,
  ) async {
    // The guard must not become a lock. A mirror the user has switched off has
    // no claim on the keyboard, and focusing the active pane is a real
    // convenience that has to keep working.
    await pumpBoth(tester);
    await clickTheMirror(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    focusActivePane();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();

    expect(shellSaw, ['z']);
    expect(sink.sent, isEmpty);
  });

  testWidgets('a text field still keeps the keyboard, as it always did', (
    tester,
  ) async {
    // The rule this replaced was not wrong, only too narrow — so the case it
    // did cover has to keep working.
    final field = FocusNode(debugLabel: 'field');
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(focusNode: field, autofocus: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(keyboardIsSpokenFor(), isTrue);
  });
}
