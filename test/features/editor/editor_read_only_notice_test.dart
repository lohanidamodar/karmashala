import 'package:flutter/material.dart';
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

const _path = r'C:\repo\build\bundle.js';

/// Hands back a file too large to edit, so the tab opens in the viewer.
class _HugeStore extends DocumentStore {
  static final _text = List.generate(60000, (i) => 'var x$i = $i;').join('\n');

  @override
  Future<SourceDocument> load(String hostPath) async => SourceDocument(
    hostPath: hostPath,
    text: _text,
    savedText: _text,
    mode: _text.length > kEditableSizeLimit
        ? DocumentMode.view
        : DocumentMode.edit,
  );

  @override
  Future<FileStamp?> stamp(String hostPath) async => null;

  @override
  Future<FileStamp> write(String hostPath, String text) =>
      throw UnimplementedError();
}

/// The read-only notice sits above the viewer in a tab that can be a narrow
/// split, so it must never take the viewer's height or break its layout.
void main() {
  const height = 400.0;
  for (final width in [240.0, 320.0, 480.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('the read-only notice leaves the viewer its height at '
          '${width}x$height @${scale}x', (tester) async {
        final db = CountingDatabase();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(database: db),
            documentStoreProvider.overrideWithValue(_HugeStore()),
          ],
        );
        addTearDown(container.dispose);

        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) => errors.add('${details.exception}');
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: AppTheme.dark(),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: const EditorTabView(hostPath: _path),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          await tester.pump();
        } finally {
          FlutterError.onError = previous;
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        }

        expect(errors, isEmpty);
        expect(find.textContaining('Read-only'), findsOneWidget);
        final editor = tester.getRect(find.byType(AppCodeEditor));
        expect(
          editor.height,
          greaterThanOrEqualTo(height * 0.6),
          reason: 'the viewer keeps most of the tab',
        );
        // The viewer's caret blinks on a timer that outlives its widget;
        // unfocused, it stops.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
