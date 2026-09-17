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

import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

const _path = '/repo/lib/main.dart';

class _MemoryStore extends DocumentStore {
  final disk = <String, String>{_path: 'void main() {}\n'};
  var writes = 0;

  @override
  Future<SourceDocument> load(String hostPath) async => SourceDocument(
    hostPath: hostPath,
    text: disk[hostPath]!,
    savedText: disk[hostPath]!,
    stamp: await stamp(hostPath),
  );

  @override
  Future<FileStamp?> stamp(String hostPath) async =>
      FileStamp(length: disk[hostPath]!.length, modified: DateTime.utc(2026));

  @override
  Future<FileStamp> write(String hostPath, String text) async {
    writes++;
    disk[hostPath] = text;
    return (await stamp(hostPath))!;
  }
}

/// **The save chord writes the file from a focused editor tab.** The owner's
/// report: Cmd+S did nothing in the installed build, because `re_editor`
/// consumed the chord before the tab's binding could hear it.
void main() {
  Future<_MemoryStore> open(WidgetTester tester) async {
    final db = CountingDatabase();
    addTearDown(db.close);
    final store = _MemoryStore();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        documentStoreProvider.overrideWithValue(store),
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
    return store;
  }

  testWidgets('Ctrl+S from the focused buffer writes the file', (tester) async {
    final store = await open(tester);
    final editor = tester.widget<AppCodeEditor>(find.byType(AppCodeEditor));
    editor.focusNode!.requestFocus();
    editor.controller.text = 'void main() { print(1); }\n';
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();

    expect(store.writes, 1);
    expect(store.disk[_path], 'void main() { print(1); }\n');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
