import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/editor/presentation/editor_tab_view.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/window_matrix.dart';
import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

const _path = '/repo/lib/main.dart';

class _Store extends DocumentStore {
  static final _text = List.generate(
    200,
    (i) => 'final value$i = compute($i); // line $i',
  ).join('\n');

  @override
  Future<SourceDocument> load(String hostPath) async => SourceDocument(
    hostPath: hostPath,
    text: _text,
    savedText: _text,
    language: 'dart',
  );

  @override
  Future<FileStamp?> stamp(String hostPath) async => null;

  @override
  Future<FileStamp> write(String hostPath, String text) async =>
      FileStamp(length: text.length, modified: null);
}

/// A file tab with find and replace open, in the smallest window the app
/// supports and at large text: a workbench tab gets the window's width, and a
/// split can take half of that, which the kit's own 240px case covers.
void main() {
  testWidgets('a file tab with find and replace open survives the matrix', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: () {
        final db = CountingDatabase();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(database: db),
            documentStoreProvider.overrideWithValue(_Store()),
          ],
        );
        addTearDown(container.dispose);
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const Scaffold(body: EditorTabView(hostPath: _path)),
          ),
        );
      },
      warmUp: (tester) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        final search = tester
            .state<AppCodeEditorState>(find.byType(AppCodeEditor))
            .findController;
        expect(search.replaceShown, isTrue);
        search.findInputController.text = 'value1';
        await tester.pump(Latency.searchDebounce);
        await tester.pump();
        expect(search.matchCount, greaterThan(0));
      },
      // Tab indents in a code buffer, as it does in every editor, so a focus
      // ring through the tab cannot close by design.
      checkFocus: false,
      because:
          'the find strip must keep Previous, Next, Close and both replace '
          'actions on screen at 720x560 and at 1.3x text',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
