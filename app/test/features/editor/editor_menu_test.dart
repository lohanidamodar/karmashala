import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/editor/presentation/editor_menu_actions.dart';
import 'package:karmashala/src/features/editor/presentation/editor_tab_view.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/theme.dart';

import '../terminal/fake_instance.dart';
import '../../support/test_machine.dart';

const _root = '/repo';
const _path = '/repo/lib/main.dart';

class _MemoryStore extends DocumentStore {
  _MemoryStore(this.text, {this.mode = DocumentMode.edit});

  final String text;
  final DocumentMode mode;

  @override
  Future<SourceDocument> load(String hostPath) async => SourceDocument(
    hostPath: hostPath,
    text: text,
    savedText: text,
    language: 'dart',
    mode: mode,
  );

  @override
  Future<FileStamp?> stamp(String hostPath) async => null;

  @override
  Future<FileStamp> write(
    String hostPath,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async => FileStamp(length: text.length, modified: DateTime.utc(2026));
}

class _Clipboard {
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

/// **A file tab's right-click menu**: the editor's own entries, then the ones
/// only a file has — its path three ways, where it lives, and what a selection
/// can become.
void main() {
  group('entries', () {
    Map<String, bool> byValue(List<PopupMenuEntry<String>> items) => {
      for (final item in items.whereType<DesktopMenuItem<String>>())
        item.value!: item.enabled,
    };

    test('a file outside the Files panel root has no relative path', () {
      expect(byValue(editorFileMenuItems(relativeRoot: null)), {
        EditorMenuValues.copyPath: true,
        EditorMenuValues.copyRelativePath: false,
        EditorMenuValues.copyPathLine: true,
        EditorMenuValues.revealInFiles: false,
        EditorMenuValues.openExternally: true,
        EditorMenuValues.openFolder: true,
      });
      expect(
        byValue(
          editorFileMenuItems(relativeRoot: _root),
        )[EditorMenuValues.revealInFiles],
        isTrue,
      );
    });

    test('a selection is offered to a note and to a session', () {
      expect(
        editorSelectionMenuItems(
          hasSelection: false,
          notesEnabled: true,
          offerNote: true,
          hasSession: true,
        ),
        isEmpty,
      );
      expect(
        byValue(
          editorSelectionMenuItems(
            hasSelection: true,
            notesEnabled: true,
            offerNote: true,
            hasSession: false,
          ),
        ),
        {
          EditorMenuValues.selectionToNote: true,
          EditorMenuValues.selectionToSession: false,
        },
      );
      expect(
        byValue(
          editorSelectionMenuItems(
            hasSelection: true,
            notesEnabled: false,
            offerNote: true,
            hasSession: true,
          ),
        ).keys,
        [EditorMenuValues.selectionToSession],
      );
    });

    test('a relative path keeps the separators of its root', () {
      expect(relativeHostPath('/repo', '/repo/lib/a.dart'), 'lib/a.dart');
      expect(
        relativeHostPath(r'C:\repo', r'C:\repo\lib\a.dart'),
        r'lib\a.dart',
      );
    });
  });

  group('in a tab', () {
    late _Clipboard clipboard;
    late ProviderContainer container;

    Future<void> open(
      WidgetTester tester, {
      DocumentMode mode = DocumentMode.edit,
    }) async {
      clipboard = _Clipboard();
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
      final db = TestMachine();
      container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          documentStoreProvider.overrideWithValue(
            _MemoryStore('void main() {}\nfinal a = 1;\n', mode: mode),
          ),
          selectedRepoWindowsRootProvider.overrideWithValue(_root),
          focusedSessionIdProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const Scaffold(body: EditorTabView(hostPath: _path)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    CodeLineEditingController editor(WidgetTester tester) =>
        tester.widget<AppCodeEditor>(find.byType(AppCodeEditor)).controller;

    Future<void> rightClick(WidgetTester tester) async {
      await tester.tap(find.byType(AppCodeEditor), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    Future<void> teardown(WidgetTester tester) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
    }

    testWidgets('path entries copy the path, relative path and path:line', (
      tester,
    ) async {
      await open(tester);
      editor(tester).selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 2,
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('Cut'), findsOneWidget, reason: "the editor's own");
      await pick(tester, 'Copy path:line');
      expect(clipboard.text, '$_path:2');

      await rightClick(tester);
      await pick(tester, 'Copy relative path');
      expect(clipboard.text, 'lib/main.dart');

      await rightClick(tester);
      await pick(tester, 'Copy path');
      expect(clipboard.text, _path);
      await teardown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('reveal selects the file in the Files panel', (tester) async {
      await open(tester);
      await rightClick(tester);
      await pick(tester, 'Reveal in Files panel');

      expect(container.read(fileRevealTargetProvider)?.hostPath, _path);
      expect(container.read(sidePanelProvider), SidePanelSurface.files);
      await teardown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('word wrap flips the editor setting', (tester) async {
      await open(tester);
      final before = container.read(settingsControllerProvider).editorWordWrap;
      await rightClick(tester);
      await pick(tester, 'Word wrap');

      expect(
        container.read(settingsControllerProvider).editorWordWrap,
        !before,
      );
      await teardown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a selection offers a note, and a session only when there is '
        'one', (tester) async {
      await open(tester);
      editor(tester).selectAll();
      await tester.pump();
      await rightClick(tester);

      expect(find.text('Create note from selection'), findsOneWidget);
      final send = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('Send selection to session'),
          matching: find.byWidgetPredicate((w) => w is PopupMenuItem<String>),
        ),
      );
      expect(send.enabled, isFalse, reason: 'no session is focused');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await teardown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });
}
