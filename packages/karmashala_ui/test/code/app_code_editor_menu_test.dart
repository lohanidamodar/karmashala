import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/menus.dart';

import 'code_editor_harness.dart';

/// The system clipboard as the platform channel sees it.
class FakeClipboard {
  String? text;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        text = (call.arguments as Map)['text'] as String?;
      case 'Clipboard.getData':
        return text == null ? null : {'text': text};
      case 'Clipboard.hasStrings':
        return {'value': text?.isNotEmpty ?? false};
    }
    return null;
  }
}

/// The editor's right-click menu: which entries a state offers and enables,
/// what each one does, and the keyboard's way to it.
void main() {
  final linux = desktop(TargetPlatform.linux);

  group('which entries, enabled when', () {
    Map<String, bool> entries({
      bool readOnly = false,
      bool hasSelection = false,
      bool canUndo = false,
      bool canRedo = false,
      bool canPaste = false,
      bool canComment = false,
      bool? wrap,
    }) => {
      for (final item in codeEditorMenuItems(
        readOnly: readOnly,
        hasSelection: hasSelection,
        canUndo: canUndo,
        canRedo: canRedo,
        canPaste: canPaste,
        canComment: canComment,
        wrap: wrap,
      ))
        if (item is DesktopMenuItem<String>) item.value!: item.enabled,
    };

    test('an editable buffer with nothing selected or copied', () {
      expect(entries(), {
        CodeEditorMenuValues.undo: false,
        CodeEditorMenuValues.redo: false,
        CodeEditorMenuValues.cut: false,
        CodeEditorMenuValues.copy: false,
        CodeEditorMenuValues.paste: false,
        CodeEditorMenuValues.selectAll: true,
        CodeEditorMenuValues.find: true,
        CodeEditorMenuValues.replace: true,
        CodeEditorMenuValues.goToLine: true,
      });
    });

    test('a selection, a clipboard and history enable what they feed', () {
      final on = entries(
        hasSelection: true,
        canPaste: true,
        canUndo: true,
        canRedo: true,
        canComment: true,
        wrap: false,
      );
      expect(on.values.every((enabled) => enabled), isTrue);
      expect(on.keys, contains(CodeEditorMenuValues.toggleComment));
      expect(on.keys, contains(CodeEditorMenuValues.wordWrap));
    });

    test(
      'read-only keeps copy, find and go to line, and nothing that edits',
      () {
        expect(
          entries(
            readOnly: true,
            hasSelection: true,
            canPaste: true,
            canComment: true,
          ),
          {
            CodeEditorMenuValues.copy: true,
            CodeEditorMenuValues.selectAll: true,
            CodeEditorMenuValues.find: true,
            CodeEditorMenuValues.goToLine: true,
          },
        );
      },
    );

    test('line comments are known for common languages only', () {
      expect(lineCommentPrefixFor('dart'), '//');
      expect(lineCommentPrefixFor('python'), '#');
      expect(lineCommentPrefixFor('sql'), '--');
      expect(lineCommentPrefixFor('markdown'), isNull);
      expect(lineCommentPrefixFor(null), isNull);
    });
  });

  group('in the editor', () {
    late FakeClipboard clipboard;
    late CodeLineEditingController controller;
    late FocusNode focus;

    setUp(() => clipboard = FakeClipboard());

    Future<void> open(
      WidgetTester tester, {
      String text = 'first line\nsecond line\n',
      bool readOnly = false,
      String? language,
      ValueChanged<bool>? onWrapChanged,
      List<PopupMenuEntry<String>> Function(CodeEditorMenuContext)? menuItems,
      void Function(String, CodeEditorMenuContext)? onMenuItem,
    }) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        clipboard.handle,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      controller = CodeLineEditingController.fromText(text);
      focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await pumpEditor(
        tester,
        AppCodeEditor(
          controller: controller,
          focusNode: focus,
          readOnly: readOnly,
          language: language,
          onWrapChanged: onWrapChanged,
          menuItems: menuItems,
          onMenuItem: onMenuItem,
        ),
      );
    }

    Future<void> teardown(WidgetTester tester) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
    }

    Future<void> rightClick(WidgetTester tester) async {
      await tester.tap(find.byType(AppCodeEditor), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    void selectFirstWord() => controller.selection = const CodeLineSelection(
      baseIndex: 0,
      baseOffset: 0,
      extentIndex: 0,
      extentOffset: 5,
    );

    bool enabled(WidgetTester tester, String label) => tester
        .widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem<String>),
          ),
        )
        .enabled;

    testWidgets('a right-click opens the menu, with its chords', (
      tester,
    ) async {
      await open(tester);
      await rightClick(tester);

      for (final label in [
        'Undo',
        'Cut',
        'Copy',
        'Paste',
        'Select all',
        'Find…',
        'Replace…',
        'Go to line…',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Ctrl+C'), findsOneWidget);
      expect(find.text('Ctrl+H'), findsOneWidget);
      expect(find.text('Ctrl+G'), findsOneWidget);
      expect(enabled(tester, 'Copy'), isFalse, reason: 'nothing selected');
      expect(enabled(tester, 'Paste'), isFalse, reason: 'clipboard empty');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await teardown(tester);
    }, variant: linux);

    testWidgets('Copy copies the selection the menu opened on', (tester) async {
      await open(tester);
      selectFirstWord();
      await tester.pump();
      // Opened from the keyboard, so the pointer cannot move the caret.
      await chord(tester, LogicalKeyboardKey.f10, shift: true);
      await tester.pumpAndSettle();
      expect(enabled(tester, 'Copy'), isTrue);

      await pick(tester, 'Copy');
      expect(clipboard.text, 'first');
      expect(controller.selectedText, 'first');
      expect(focus.hasFocus, isTrue);
      await teardown(tester);
    }, variant: linux);

    testWidgets('Cut removes the selection onto the clipboard, Undo puts it '
        'back, and Paste inserts it', (tester) async {
      await open(tester);
      selectFirstWord();
      await tester.pump();

      await chord(tester, LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await pick(tester, 'Cut');
      expect(clipboard.text, 'first');
      expect(controller.text, ' line\nsecond line\n');

      await chord(tester, LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(enabled(tester, 'Undo'), isTrue);
      expect(enabled(tester, 'Paste'), isTrue);
      await pick(tester, 'Undo');
      expect(controller.text, 'first line\nsecond line\n');

      controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 0,
      );
      await chord(tester, LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await pick(tester, 'Paste');
      await tester.pump();
      expect(controller.text, 'first line\nfirstsecond line\n');
      await teardown(tester);
    }, variant: linux);

    testWidgets('Select all, Find and Replace', (tester) async {
      await open(tester);
      await chord(tester, LogicalKeyboardKey.f10, shift: true);
      await tester.pumpAndSettle();
      await pick(tester, 'Select all');
      expect(controller.selectedText, 'first line\nsecond line\n');

      await chord(tester, LogicalKeyboardKey.f10, shift: true);
      await tester.pumpAndSettle();
      await pick(tester, 'Replace…');
      final search = tester
          .state<AppCodeEditorState>(find.byType(AppCodeEditor))
          .findController;
      expect(search.isOpen, isTrue);
      expect(search.replaceShown, isTrue);
      await teardown(tester);
    }, variant: linux);

    testWidgets('a right-click inside a selection keeps it', (tester) async {
      await open(tester);
      controller.selectAll();
      await tester.pump();

      await rightClick(tester);
      expect(enabled(tester, 'Copy'), isTrue);
      await pick(tester, 'Copy');
      expect(clipboard.text, 'first line\nsecond line\n');
      await teardown(tester);
    }, variant: linux);

    testWidgets('read-only offers nothing that edits', (tester) async {
      clipboard.text = 'x';
      await open(tester, readOnly: true);
      await rightClick(tester);

      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Find…'), findsOneWidget);
      for (final label in ['Cut', 'Paste', 'Undo', 'Replace…']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await teardown(tester);
    }, variant: linux);

    testWidgets('toggle line comment and word wrap', (tester) async {
      bool? wrapped;
      await open(
        tester,
        language: 'dart',
        onWrapChanged: (value) => wrapped = value,
      );
      await chord(tester, LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await pick(tester, 'Toggle line comment');
      expect(controller.text, '// first line\nsecond line\n');
      controller.undo();

      await chord(tester, LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await pick(tester, 'Word wrap');
      expect(wrapped, isTrue);
      await teardown(tester);
    }, variant: linux);

    testWidgets("a caller's entries follow the editor's, told the context", (
      tester,
    ) async {
      CodeEditorMenuContext? seen;
      String? picked;
      await open(
        tester,
        menuItems: (context) => [
          DesktopMenuItem(
            value: 'copy-path-line',
            label: 'Copy path:line',
            icon: Icons.abc,
            enabled: context.line > 0,
          ),
        ],
        onMenuItem: (value, context) {
          picked = value;
          seen = context;
        },
      );
      controller.selection = const CodeLineSelection(
        baseIndex: 1,
        baseOffset: 0,
        extentIndex: 1,
        extentOffset: 6,
      );
      await chord(tester, LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await pick(tester, 'Copy path:line');

      expect(picked, 'copy-path-line');
      expect(seen!.line, 2);
      expect(seen!.selectedText, 'second');
      await teardown(tester);
    }, variant: linux);
  });
}
