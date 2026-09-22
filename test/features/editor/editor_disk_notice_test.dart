import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/editor/presentation/disk_change_notice.dart';
import 'package:karmashala/src/features/editor/presentation/editor_tab_view.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/theme.dart';

import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

const _path = r'C:\repo\lib\main.dart';

final _lines = [for (var i = 0; i < 200; i++) 'line $i of the file'];
final _initial = '${_lines.join('\n')}\n';

/// A disk another process writes behind the editor's back.
class _Disk extends DocumentStore {
  final Map<String, String> files = {_path: _initial};
  final Map<String, DateTime> _modified = {};
  var _clock = 0;
  var stats = 0;

  void external(String? text) {
    if (text == null) {
      files.remove(_path);
    } else {
      files[_path] = text;
    }
    _modified[_path] = DateTime.utc(2026, 9, 22, 12, 0, ++_clock);
  }

  @override
  Future<SourceDocument> load(String hostPath) async {
    final text = files[hostPath];
    if (text == null) {
      return SourceDocument(
        hostPath: hostPath,
        text: '',
        savedText: '',
        refusal: DocumentRefusal.notFound,
        error: 'not found',
      );
    }
    return SourceDocument(
      hostPath: hostPath,
      text: text,
      savedText: text,
      stamp: _stampOf(hostPath),
    );
  }

  FileStamp? _stampOf(String hostPath) {
    final text = files[hostPath];
    if (text == null) return null;
    return FileStamp(length: text.length, modified: _modified[hostPath]);
  }

  @override
  Future<FileStamp?> stamp(String hostPath) async {
    stats++;
    return _stampOf(hostPath);
  }

  @override
  Future<FileStamp> write(
    String hostPath,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async {
    external(text);
    return _stampOf(hostPath)!;
  }
}

/// **The editor picks up a file changed on disk**: silently when nothing is
/// typed, with a bar that asks when something is.
void main() {
  late _Disk disk;
  late ProviderContainer container;

  Future<void> pumpView(WidgetTester tester, {required bool showing}) =>
      tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 900,
                  height: 600,
                  child: EditorTabView(hostPath: _path, showing: showing),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> mount(WidgetTester tester, {bool showing = true}) async {
    final db = CountingDatabase();
    addTearDown(db.close);
    disk = _Disk();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        documentStoreProvider.overrideWithValue(disk),
      ],
    );
    addTearDown(container.dispose);
    await pumpView(tester, showing: showing);
    await tester.pump();
    await tester.pump();
  }

  Future<void> teardown(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
  }

  CodeLineEditingController controller(WidgetTester tester) =>
      tester.widget<AppCodeEditor>(find.byType(AppCodeEditor)).controller;

  /// One poll's worth of time, and the frames its stat and read resolve in.
  Future<void> poll(WidgetTester tester) async {
    await tester.pump(EditorTabView.diskPollInterval);
    await tester.pump();
    await tester.pump();
  }

  SourceDocument doc() => container.read(openDocumentProvider(_path))!;

  testWidgets('a clean buffer takes the new text, caret and scroll kept', (
    tester,
  ) async {
    await mount(tester);
    final field = controller(tester);
    field.selection = const CodeLineSelection(
      baseIndex: 120,
      baseOffset: 2,
      extentIndex: 121,
      extentOffset: 6,
    );
    await tester.pump();
    final scroll = tester
        .stateList<ScrollableState>(
          find.descendant(
            of: find.byType(AppCodeEditor),
            matching: find.byType(Scrollable),
          ),
        )
        .firstWhere((s) => s.position.axis == Axis.vertical)
        .position;
    scroll.jumpTo(scroll.maxScrollExtent / 2);
    await tester.pump();
    final offset = scroll.pixels;
    expect(offset, greaterThan(0), reason: 'a scroll worth keeping');

    disk.external('$_initial// appended by an agent\n');
    await poll(tester);

    expect(field.text, '$_initial// appended by an agent\n');
    expect(doc().isDirty, isFalse);
    expect(find.text('Changed on disk'), findsNothing);
    expect(field.selection.baseIndex, 120);
    expect(field.selection.baseOffset, 2);
    expect(field.selection.extentIndex, 121);
    expect(field.selection.extentOffset, 6);
    expect(scroll.pixels, offset);
    await teardown(tester);
  });

  testWidgets('a selection past the new end is pulled inside it', (
    tester,
  ) async {
    await mount(tester);
    final field = controller(tester);
    field.selection = const CodeLineSelection.collapsed(index: 150, offset: 9);
    await tester.pump();

    disk.external('short\nfile\n');
    await poll(tester);

    expect(tester.takeException(), isNull);
    expect(field.text, 'short\nfile\n');
    expect(field.selection.baseIndex, lessThan(field.lineCount));
    await teardown(tester);
  });

  group('a dirty buffer', () {
    Future<void> conflict(WidgetTester tester) async {
      await mount(tester);
      container.read(openDocumentsProvider.notifier).edit(_path, 'mine\n');
      await tester.pump();
      disk.external('theirs\n');
      await poll(tester);
    }

    testWidgets('keeps the edits and shows the bar', (tester) async {
      await conflict(tester);

      expect(controller(tester).text, 'mine\n');
      expect(find.textContaining('Changed on disk'), findsOneWidget);
      expect(find.text('Keep mine'), findsOneWidget);
      expect(find.text('Reload (discard mine)'), findsOneWidget);
      expect(find.text('Compare'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('Keep mine dismisses it, and the save then overwrites', (
      tester,
    ) async {
      await conflict(tester);

      await tester.tap(find.text('Keep mine'));
      await tester.pump();
      expect(find.textContaining('Changed on disk'), findsNothing);
      // The same change does not bring it back.
      await poll(tester);
      expect(find.textContaining('Changed on disk'), findsNothing);

      await tester.tap(find.byTooltip('Save (Ctrl+S)'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing, reason: 'no 2nd prompt');
      expect(disk.files[_path], 'mine\n');
      await teardown(tester);
    });

    testWidgets('Reload discards the edits for the disk, without asking', (
      tester,
    ) async {
      await conflict(tester);

      await tester.tap(find.text('Reload (discard mine)'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(controller(tester).text, 'theirs\n');
      expect(find.textContaining('Changed on disk'), findsNothing);
      await teardown(tester);
    });

    testWidgets('Compare shows the disk against the buffer', (tester) async {
      await conflict(tester);

      await tester.tap(find.text('Compare'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('on disk (−) and yours (+)'), findsOneWidget);
      expect(find.textContaining('theirs'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(find.textContaining('Changed on disk'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('a save before answering still stops at the dialog', (
      tester,
    ) async {
      await conflict(tester);

      await tester.tap(find.byTooltip('Save (Ctrl+S)'));
      await tester.pump();
      await tester.pump();

      expect(find.text('This file changed on disk'), findsOneWidget);
      expect(disk.files[_path], 'theirs\n');
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await teardown(tester);
    });
  });

  testWidgets('a deleted file keeps its text, and saving recreates it', (
    tester,
  ) async {
    await mount(tester);

    disk.external(null);
    await poll(tester);

    expect(controller(tester).text, _initial);
    expect(find.textContaining('Deleted on disk'), findsOneWidget);
    expect(
      find.textContaining(
        RegExp(r'main\.dart \(deleted on disk\)', caseSensitive: false),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Save to recreate'));
    await tester.pump();
    await tester.pump();

    expect(disk.files[_path], _initial);
    expect(find.textContaining('Deleted on disk'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a hidden editor does not poll; showing it checks at once', (
    tester,
  ) async {
    await mount(tester, showing: false);
    final before = disk.stats;

    disk.external('changed while hidden\n');
    await poll(tester);
    await poll(tester);
    expect(disk.stats, before);
    expect(controller(tester).text, _initial);

    await pumpView(tester, showing: true);
    await tester.pump();
    await tester.pump();

    expect(controller(tester).text, 'changed while hidden\n');
    await teardown(tester);
  });

  test('clampSelection keeps what fits and pulls in what does not', () {
    const selection = CodeLineSelection(
      baseIndex: 1,
      baseOffset: 3,
      extentIndex: 9,
      extentOffset: 40,
    );
    final clamped = clampSelection(selection, [5, 5, 2]);
    expect(clamped.baseIndex, 1);
    expect(clamped.baseOffset, 3);
    expect(clamped.extentIndex, 2);
    expect(clamped.extentOffset, 2);
    expect(clampSelection(selection, const []).baseIndex, 0);
  });
}
